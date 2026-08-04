#!/usr/bin/env python3
"""
serve.py - Local development HTTP server with Cross-Origin Isolation headers
(COOP and COEP) required for WebAssembly SharedArrayBuffer and pthreads.
"""

import argparse
import http.server
import mimetypes
import os
import socketserver
import sys

# Ensure correct MIME type mapping for WebAssembly
mimetypes.add_type("application/wasm", ".wasm")
mimetypes.add_type("application/javascript", ".js")
http.server.SimpleHTTPRequestHandler.extensions_map[".wasm"] = "application/wasm"
http.server.SimpleHTTPRequestHandler.extensions_map[".js"] = "application/javascript"

class CrossOriginIsolatedRequestHandler(http.server.SimpleHTTPRequestHandler):
    """HTTP request handler that sets COOP and COEP headers on all responses."""

    def end_headers(self):
        # Required for SharedArrayBuffer and multithreaded WebAssembly
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

def main():
    parser = argparse.ArgumentParser(
        description="Serve demos over HTTP with COOP and COEP headers for SharedArrayBuffer support."
    )
    parser.add_argument(
        "-p", "--port", type=int, default=8080, help="Port to listen on (default: 8080)"
    )
    parser.add_argument(
        "-d", "--directory", default=".", help="Root directory to serve (default: .)"
    )
    args = parser.parse_args()

    os.chdir(args.directory)

    # Enable port reuse so restarting the server doesn't hit "Address already in use"
    socketserver.TCPServer.allow_reuse_address = True

    with socketserver.TCPServer(("", args.port), CrossOriginIsolatedRequestHandler) as httpd:
        print(f"Serving HTTP with COOP/COEP on port {args.port} (http://localhost:{args.port}/)...")
        print("\nAvailable demos:")
        build_dir = "build"
        if os.path.exists(build_dir):
            for demo in sorted(os.listdir(build_dir)):
                demo_path = os.path.join(build_dir, demo, "main.html")
                if os.path.exists(demo_path):
                    print(f"  - http://localhost:{args.port}/{demo_path}")
        print("\nPress Ctrl+C to stop the server.")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\nShutting down server.")

if __name__ == "__main__":
    main()
