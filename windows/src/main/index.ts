// Vigil for Windows — core entry point.
//
// A plain Node process (never the Electron main process) so node-pty runs against the
// Node ABI. Prints one ready line with the loopback URL the Electron shell loads.

import { randomBytes } from 'node:crypto'
import { SessionManager } from './session-manager.js'
import { startServer } from './server.js'
import { writeDetected } from './prober.js'

async function main(): Promise<void> {
  const manager = new SessionManager()
  manager.bootstrap()
  writeDetected(manager.detected)

  const token = randomBytes(16).toString('hex')
  const port = process.env.VIGIL_PORT ? Number(process.env.VIGIL_PORT) : 0
  const handle = await startServer(manager, { port, token })
  const url = `http://127.0.0.1:${handle.port}/?token=${token}`
  console.log(`VIGIL_READY ${JSON.stringify({ port: handle.port, url })}`)

  const shutdown = () => {
    try {
      handle.close()
    } catch {
      // ignore
    }
    manager.shutdown()
    process.exit(0)
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
  process.on('SIGHUP', shutdown)
  process.on('uncaughtException', (err) => {
    console.error('uncaught:', err)
  })
  process.on('unhandledRejection', (err) => {
    console.error('unhandled rejection:', err)
  })
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
