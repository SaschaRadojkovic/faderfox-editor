#!/bin/bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="$ROOT/.ec4-bridge-venv"
URL="http://localhost:8321/ec4-v2/index.html"

cd "$ROOT" || exit 1

pause_on_error() {
  echo
  read -r -p "Zum Schließen Enter drücken …"
}

if curl -fsS "http://127.0.0.1:8321/__ec4_bridge_health" >/dev/null 2>&1; then
  echo "Der EC4 Editor läuft bereits. Chrome wird geöffnet."
  open -a "Google Chrome" "$URL"
  exit 0
fi

if lsof -ti tcp:8321 >/dev/null 2>&1; then
  echo "FEHLER: Port 8321 wird bereits von einem anderen Programm verwendet."
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
  echo "FEHLER: Python 3 wurde nicht gefunden."
  pause_on_error
  exit 1
fi

if [ ! -x "$VENV/bin/python" ]; then
  echo "Einmalige Einrichtung der lokalen MIDI-Brücke …"
  "$PYTHON" -m venv "$VENV" || {
    echo "FEHLER: Python-Umgebung konnte nicht erstellt werden."
    pause_on_error
    exit 1
  }
fi

if ! "$VENV/bin/python" -c "import rtmidi" >/dev/null 2>&1; then
  echo "Installiere einmalig die MIDI-Komponente …"
  "$VENV/bin/python" -m pip install -r "$ROOT/tools/requirements.txt" || {
    echo "FEHLER: MIDI-Komponente konnte nicht installiert werden."
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
    echo "Chrome wird geöffnet …"
    open -a "Google Chrome" "$URL"
    wait "$SERVER_PID"
    exit $?
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

echo "FEHLER: Der EC4 Editor konnte nicht gestartet werden."
pause_on_error
exit 1
