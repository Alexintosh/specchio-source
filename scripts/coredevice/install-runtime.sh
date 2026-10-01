#!/bin/bash
# Install the pinned experimental helper runtime independently of global Python.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
runtime="$HOME/Library/Application Support/Specchio/CoreDevice/venv"
python_bin="${1:-python3.13}"
if [ ! -x "$runtime/bin/python3" ]; then
  "$python_bin" -m venv "$runtime"
fi
"$runtime/bin/python3" -m pip install -r "$script_dir/requirements.lock.txt"
"$runtime/bin/python3" -c 'import importlib.metadata; assert importlib.metadata.version("pymobiledevice3") == "11.13.1"; print("CoreDevice runtime ready: pymobiledevice3 11.13.1")'
