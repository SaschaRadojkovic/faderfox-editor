#!/bin/bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="$ROOT/.ec4-bridge-venv"
URL="http://localhost:8321/ec4-v2/index.html"

cd "$ROOT" || exit 1

pause_on_error() {
  echo
  read -r -p "Press Enter to close …"
}

if curl -fsS "http://127.0.0.1:8321/__ec4_bridge_health" >/dev/null 2>&1; then
  echo "The EC4 Editor is already running. Opening Chrome."
  open -a "Google Chrome" "$URL"
  exit 0
fi

if lsof -ti tcp:8321 >/dev/null 2>&1; then
  echo "ERROR: Port 8321 is already in use by another program."
  pause_on_error
  exit 1
fi

PYTHON=""
for candidate in \
  /opt/homebrew/bin/python3.12 \
  python3.12 \
  python3.11 \
  python3.10 \
  /usr/bin/python3 \
  python3.13 \
  python3
do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done

if [ -z "$PYTHON" ]; then
  echo "ERROR: Python 3 was not found."
  pause_on_error
  exit 1
fi

if [ ! -x "$VENV/bin/python" ]; then
  echo "Setting up the local MIDI bridge for the first time …"
  "$PYTHON" -m venv "$VENV" || {
    echo "ERROR: Could not create the Python environment."
    pause_on_error
    exit 1
  }
fi

if ! "$VENV/bin/python" -c "import rtmidi" >/dev/null 2>&1; then
  echo "Installing the MIDI component (one-time) …"
  "$VENV/bin/python" -m pip install -r "$ROOT/tools/requirements.txt" || {
    echo "ERROR: Could not install the MIDI component."
    pause_on_error
    exit 1
  }
fi

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

"$VENV/bin/python" "$ROOT/tools/ec4_bridge_server.py" &
SERVER_PID=$!

for _ in {1..40}; do
  if curl -fsS "http://127.0.0.1:8321/__ec4_bridge_health" >/dev/null 2>&1; then
    echo
    echo "Opening Chrome …"
    open -a "Google Chrome" "$URL"
    wait "$SERVER_PID"
    exit $?
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

echo "ERROR: Could not start the EC4 Editor."
pause_on_error
exit 1
