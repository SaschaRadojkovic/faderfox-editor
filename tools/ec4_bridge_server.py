#!/usr/bin/env python3
"""Serve the EC4 editor and bridge incoming EC4 SysEx via macOS CoreMIDI."""

import base64
import json
import os
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock, Thread
from urllib.parse import parse_qs, urlparse

import rtmidi

ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
PORT = 8321

lock = Lock()
latest_dump = b""
generation = 0
sysex_buffer = bytearray()


def midi_callback(event, _data=None):
    global latest_dump, generation, sysex_buffer
    message, _delta = event

    with lock:
        for byte in message:
            if byte == 0xF0:
                sysex_buffer = bytearray([byte])
            elif sysex_buffer:
                sysex_buffer.append(byte)
                if byte == 0xF7:
                    latest_dump = bytes(sysex_buffer)
                    generation += 1
                    print(
                        f"EC4 SysEx dump received in full: {len(latest_dump)} bytes",
                        flush=True,
                    )
                    sysex_buffer = bytearray()


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)

        if url.path == "/__ec4_bridge_health":
            self.send_json({"ok": True})
            return

        if url.path == "/__midi_bridge":
            try:
                after = int(parse_qs(url.query).get("after", ["0"])[0])
            except ValueError:
                after = 0

            with lock:
                is_new = generation > after
                payload = {
                    "generation": generation,
                    "length": len(latest_dump) if is_new else 0,
                    "data": (
                        base64.b64encode(latest_dump).decode("ascii")
                        if is_new
                        else ""
                    ),
                }
            self.send_json(payload)
            return

        super().do_GET()

    def end_headers(self):
        # Static editor files: force revalidation on every load so a
        # normal reload always picks up changes (no heuristic caching).
        if urlparse(self.path).path not in ("/__ec4_bridge_health", "/__midi_bridge"):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def send_json(self, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def find_and_open_ec4(midi_in):
    """Open the EC4 MIDI input if present. True if connected."""
    for index, name in enumerate(midi_in.get_ports()):
        if "Faderfox EC4" in name:
            midi_in.open_port(index, "EC4 Local Bridge")
            midi_in.set_callback(midi_callback)
            print(f"EC4 found: {name}", flush=True)
            return True
    return False


def main():
    os.chdir(ROOT)

    # The web server is independent of the device: the editor always loads
    # so presets can be edited offline, exactly like the hosted version.
    try:
        server = Server((HOST, PORT), Handler)
    except OSError as error:
        print(f"ERROR: Could not open port {PORT}: {error}")
        return 1

    midi_in = rtmidi.MidiIn()
    midi_in.ignore_types(sysex=False, timing=True, active_sense=True)

    connected = find_and_open_ec4(midi_in)
    if not connected:
        ports = midi_in.get_ports()
        print("NOTE: No Faderfox EC4 detected — starting in offline mode.")
        print("Available MIDI inputs:", ports or "none")
        print("Connect the EC4 now and it will be picked up automatically.")

    print(
        f"Editor available at http://localhost:{PORT}/ec4-v2/index.html",
        flush=True,
    )
    print("Keep this window open while using the editor.", flush=True)

    # Watch for the device in the background until it appears (hot-plug).
    def watch():
        while not find_and_open_ec4(midi_in):
            time.sleep(1)

    if not connected:
        Thread(target=watch, daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down EC4 Editor.")
    finally:
        midi_in.cancel_callback()
        midi_in.close_port()
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
