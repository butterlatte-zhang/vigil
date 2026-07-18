"""vt100-screen-backed cell controller — the robust upgrade over naive scrape.

Instead of regex-on-stripped-bytes, we feed the child's raw PTY output into a
real terminal emulator (pyte) and read the *rendered screen* (row/col grid).
This is what fixes the 'Doyouwanttoproceed?' word-collapse from step 2."""
import os, pty, select, time, struct, fcntl, termios
import pyte


class _TolerantScreen(pyte.Screen):
    """pyte doesn't know private DSR queries (CSI ? Ps n — e.g. claude CLI
    2.1.201 probes color scheme with one) and crashes on the unexpected
    `private` kwarg. Swallow those; plain DSR passes through unchanged."""
    def report_device_status(self, mode=0, **kwargs):
        if kwargs.get("private"):
            return
        super().report_device_status(mode)


class ScreenCell:
    def __init__(self, argv, env=None, cwd=None, rows=45, cols=120):
        self.rows, self.cols = rows, cols
        self.screen = _TolerantScreen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.master = pty.fork()
        if self.pid == 0:
            if cwd:
                os.chdir(cwd)
            os.execvpe(argv[0], argv, env or os.environ)
            os._exit(127)
        fcntl.ioctl(self.master, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, seconds):
        """Read raw bytes for `seconds`, feed the emulator. Returns rendered screen text."""
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.master], [], [], max(0, end - time.time()))
            if not r:
                break
            try:
                data = os.read(self.master, 65536)
            except OSError:
                break
            if not data:
                break
            self.stream.feed(data)
        return self.display()

    def display(self):
        # the *rendered* screen — spaces preserved exactly as drawn
        return "\n".join(self.screen.display)

    def wait_for(self, substrings, timeout=30, tick=0.5):
        """Return (matched_substring, screen) when any substring appears on the rendered screen."""
        end = time.time() + timeout
        while time.time() < end:
            scr = self.pump(tick)
            low = scr.lower()
            for s in substrings:
                if s.lower() in low:
                    return s, scr
            if self._dead():
                return None, scr
        return None, self.display()

    def send(self, data):
        os.write(self.master, data.encode() if isinstance(data, str) else data)

    def _dead(self):
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            return pid != 0
        except OSError:
            return True

    def close(self):
        try: os.close(self.master)
        except OSError: pass
        try: os.waitpid(self.pid, 0)
        except OSError: pass
