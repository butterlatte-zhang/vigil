"""Minimal zero-dependency PTY controller — the 'task wraps a terminal' primitive.

A parent process owns a pseudo-terminal, spawns an arbitrary interactive program
(a stand-in agent, or real `claude`) as its child, watches the child's output
stream, and can inject input. This is the core mechanism Vigil's 'terminal takeover'
claim rests on. stdlib only (pty/os/select) — no pexpect.
"""
import os, pty, select, re, time, sys, struct, fcntl, termios


class Terminal:
    def __init__(self, argv, env=None, cwd=None, logfile=None, winsize=(40, 120)):
        self.argv = argv
        self.transcript = bytearray()      # everything the child emitted
        self.logfile = logfile
        self.pid, self.master = pty.fork()
        if self.pid == 0:                  # child: stdio is the pty slave
            if cwd:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, env or os.environ)
            os._exit(127)                  # unreachable on success
        # parent: give the pty a real window size so TUIs render
        rows, cols = winsize
        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))

    def _drain(self, timeout):
        """Read whatever the child has emitted within `timeout` seconds."""
        out = bytearray()
        end = time.time() + timeout
        while True:
            remaining = end - time.time()
            if remaining <= 0:
                break
            r, _, _ = select.select([self.master], [], [], remaining)
            if not r:
                break
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            self.transcript += chunk
            if self.logfile:
                self.logfile.write(chunk)
                self.logfile.flush()
        return bytes(out)

    def expect(self, patterns, timeout=30, quiet_after=0.3):
        """Read until one of `patterns` (regex, matched against decoded tail)
        appears, or timeout. Returns (index, recent_text). -1 if timeout."""
        compiled = [re.compile(p, re.I) for p in patterns]
        buf = bytearray()
        end = time.time() + timeout
        while time.time() < end:
            data = self._drain(quiet_after)
            if data:
                buf += data
            text = self._clean(bytes(buf))
            for i, c in enumerate(compiled):
                if c.search(text):
                    return i, text
            if not data and self._dead():
                break
        return -1, self._clean(bytes(buf))

    def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        os.write(self.master, data)

    def sendline(self, line=""):
        self.send(line + "\r")

    def _dead(self):
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            return pid != 0
        except OSError:
            return True

    @staticmethod
    def _clean(b):
        text = b.decode("utf-8", "replace")
        text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", text)  # OSC
        text = re.sub(r"\x1b[@-_][0-?]*[ -/]*[@-~]", "", text)       # CSI/escape
        text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", "", text)
        return text

    def close(self):
        try:
            os.close(self.master)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass
