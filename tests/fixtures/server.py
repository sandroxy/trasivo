#!/usr/bin/env python3
"""Local deterministic transfer fixture; no authentication or external service calls."""
import argparse
import hashlib
import json
import time
import threading
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):
    # Every response has a Content-Length. Keep connection reuse consistent
    # with clients that deliberately disable automatic request retries.
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == '/failure':
            self.send_error(503); return
        if self.path == '/retry':
            with self.server.counter_lock:
                self.server.retry_count += 1
                fail = self.server.retry_count % 2 == 1
            if fail:
                self.send_error(503); return
        if self.path in ('/image', '/video'):
            path = self.server.media.get(self.path)
            if path is None:
                self.send_error(404); return
            with path.open('rb') as source:
                self.send_response(200)
                self.send_header('Content-Type', 'image/jpeg' if self.path == '/image' else 'video/mp4')
                self.send_header('Content-Length', str(path.stat().st_size))
                self.end_headers()
                try:
                    while chunk := source.read(65536):
                        self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.path not in ('/download', '/slow', '/retry'):
            self.send_error(404); return
        slow = self.path == '/slow'
        data = b'trasivo-fixture\n' * (65536 if slow else 1024)
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            for offset in range(0, len(data), 8192):
                self.wfile.write(data[offset:offset + 8192]); self.wfile.flush()
                if slow: time.sleep(0.08)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_POST(self):
        remaining = int(self.headers.get('Content-Length', '0'))
        digest = hashlib.sha256()
        while remaining > 0:
            data = self.rfile.read(min(65536, remaining))
            if not data: return
            digest.update(data); remaining -= len(data)
        body = json.dumps({'success': self.path != '/rejected', 'sha256': digest.hexdigest()}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--image', type=Path, help='Optional JPEG fixture')
    parser.add_argument('--video', type=Path, help='Optional MP4 fixture')
    options = parser.parse_args()
    server = ThreadingHTTPServer((options.host, options.port), Handler)
    server.counter_lock = threading.Lock()
    server.retry_count = 0
    server.media = {}
    for route, path in [('/image', options.image), ('/video', options.video)]:
        if path is not None:
            if not path.is_file(): parser.error(f'Media file does not exist: {path}')
            server.media[route] = path
    print(server.server_port, flush=True)
    server.serve_forever()
