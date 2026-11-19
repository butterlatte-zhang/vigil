// Vigil for Windows — newline-delimited channels over Windows named pipes.
//
// Port of the macOS app's SocketLineChannel/UDSListener. A connected named-pipe
// socket becomes a LineChannel; a listener binds a per-session pipe and hands each
// accepted connection to a handler. Same framing as the shims and MCP stdio.

import net from 'node:net'

export interface LineChannel {
  readLine(): Promise<string | null>
  write(line: string): Promise<void>
  close(): Promise<void>
}

export class SocketLineChannel implements LineChannel {
  private buffer = ''
  private eof = false
  private waiter: ((line: string | null) => void) | null = null
  private closed = false

  constructor(private readonly sock: net.Socket) {
    sock.setEncoding('utf8')
    sock.on('data', (chunk: string) => {
      this.buffer += chunk
      this.deliver()
    })
    sock.on('close', () => {
      this.eof = true
      this.deliver()
    })
    sock.on('error', () => {
      this.eof = true
      this.deliver()
    })
  }

  readLine(): Promise<string | null> {
    const idx = this.buffer.indexOf('\n')
    if (idx >= 0) {
      const line = this.buffer.slice(0, idx)
      this.buffer = this.buffer.slice(idx + 1)
      return Promise.resolve(line)
    }
    if (this.eof) return Promise.resolve(null)
    return new Promise((resolve) => {
      this.waiter = resolve
    })
  }

  private deliver(): void {
    if (!this.waiter) return
    const idx = this.buffer.indexOf('\n')
    if (idx >= 0) {
      const line = this.buffer.slice(0, idx)
      this.buffer = this.buffer.slice(idx + 1)
      const w = this.waiter
      this.waiter = null
      w(line)
    } else if (this.eof) {
      const w = this.waiter
      this.waiter = null
      w(null)
    }
  }

  write(line: string): Promise<void> {
    if (this.closed) return Promise.resolve()
    return new Promise((resolve) => {
      this.sock.write(line + '\n', () => resolve())
    })
  }

  close(): Promise<void> {
    if (this.closed) return Promise.resolve()
    this.closed = true
    this.eof = true
    try {
      this.sock.destroy()
    } catch {
      // ignore
    }
    const w = this.waiter
    this.waiter = null
    if (w) w(null)
    return Promise.resolve()
  }
}

/** Bind a Windows named pipe and serve every accepted connection. */
export class PipeListener {
  private server: net.Server | null = null

  constructor(readonly pipe: string) {}

  start(handler: (ch: SocketLineChannel) => void): Promise<void> {
    return new Promise((resolve, reject) => {
      const server = net.createServer((sock) => {
        sock.setNoDelay(true)
        handler(new SocketLineChannel(sock))
      })
      server.on('error', reject)
      server.listen(this.pipe, () => {
        this.server = server
        resolve()
      })
    })
  }

  stop(): void {
    this.server?.close()
    this.server = null
  }
}
