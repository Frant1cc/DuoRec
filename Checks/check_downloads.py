"""Local HTTP fixtures for the native Whisper downloader regression checks."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
import threading
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/model")
            self.end_headers()
            return
        if self.path == "/unavailable":
            self.send_error(503)
            return
        total = 2097152
        start = 0
        if self.headers.get("Range") and self.path != "/ignore-range":
            start = int(self.headers["Range"].split("=")[1].split("-")[0])
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(total - start))
        self.send_header("Accept-Ranges", "bytes")
        if start:
            header_start = start + 1 if self.path == "/wrong-range" else start
            self.send_header("Content-Range", f"bytes {header_start}-{total - 1}/{total}")
        self.end_headers()
        if self.path == "/stall":
            time.sleep(3)
            return
        try:
            for position in range(start, total, 65536):
                self.wfile.write(bytes([0xab]) * min(65536, total - position))
                self.wfile.flush()
                time.sleep(0.05 if self.path == "/slow" else 0.005)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(Path(sys.argv[1]).resolve()), f"http://127.0.0.1:{server.server_port}"])
    finally:
        server.shutdown()
        server.server_close()
    sys.exit(result.returncode)
