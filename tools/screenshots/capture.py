"""Capture zmachine web pages at 2x with headless Brave over the DevTools protocol.

usage: capture.py <port> <out-dir> <name> <path> <light|dark> [width height] [js-before]
"""
import base64, json, os, socket, struct, subprocess, sys, tempfile, time, urllib.request

DEBUG_PORT = 9333
BRAVE = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"


class WS:
    def __init__(self, url):
        host, rest = url[len("ws://"):].split("/", 1)
        h, p = host.split(":")
        self.s = socket.create_connection((h, int(p)))
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /{rest} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.s.recv(4096)
        self.rest = buf.split(b"\r\n\r\n", 1)[1]
        self.next_id = 1

    def _recv(self, n):
        while len(self.rest) < n:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError
            self.rest += chunk
        out, self.rest = self.rest[:n], self.rest[n:]
        return out

    def send(self, obj):
        data = json.dumps(obj).encode()
        head = bytes([0x81])
        n = len(data)
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        mask = os.urandom(4)
        self.s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def recv(self):
        message = b""
        while True:
            b0, b1 = self._recv(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._recv(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._recv(8))[0]
            message += self._recv(n)
            if b0 & 0x80:
                return json.loads(message)

    def call(self, method, **params):
        i = self.next_id
        self.next_id += 1
        self.send({"id": i, "method": method, "params": params})
        while True:
            m = self.recv()
            if m.get("id") == i:
                if "error" in m:
                    raise RuntimeError(m["error"])
                return m.get("result", {})


def main():
    port, out_dir, name, path, scheme = sys.argv[1:6]
    width, height = (int(sys.argv[6]), int(sys.argv[7])) if len(sys.argv) > 7 else (1280, 800)
    js_before = sys.argv[8] if len(sys.argv) > 8 else ""
    profile = tempfile.mkdtemp(prefix="zm-capture-")
    brave = subprocess.Popen([BRAVE, "--headless=new", f"--remote-debugging-port={DEBUG_PORT}", f"--user-data-dir={profile}",
                              "--hide-scrollbars", "--no-first-run", "--disable-extensions", "about:blank"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                pages = json.load(urllib.request.urlopen(f"http://127.0.0.1:{DEBUG_PORT}/json/list"))
                page = next(p for p in pages if p["type"] == "page")
                break
            except Exception:
                time.sleep(0.2)
        ws = WS(page["webSocketDebuggerUrl"])
        ws.call("Emulation.setDeviceMetricsOverride", width=width, height=height, deviceScaleFactor=2, mobile=False)
        ws.call("Emulation.setEmulatedMedia", features=[{"name": "prefers-color-scheme", "value": scheme}])
        base = f"http://127.0.0.1:{port}"
        ws.call("Page.navigate", url=base + "/")
        time.sleep(1.0)
        ws.call("Runtime.evaluate", expression="localStorage.setItem('zmachine-name','Ana'); 1")
        ws.call("Page.navigate", url=base + path)
        time.sleep(3.0)
        if js_before:
            ws.call("Runtime.evaluate", expression=js_before, awaitPromise=True)
            time.sleep(1.0)
        shot = ws.call("Page.captureScreenshot", format="png")
        out = os.path.join(out_dir, f"{name}-{scheme}.png")
        with open(out, "wb") as f:
            f.write(base64.b64decode(shot["data"]))
        print(out)
    finally:
        brave.terminate()
        brave.wait()


main()
