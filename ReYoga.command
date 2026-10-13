#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v python3 >/dev/null 2>&1; then
    echo 'Install Python 3.9 or newer, then run ReYoga again.' >&2
    exit 1
fi
python3 Scripts/hardware_support.py "$@"
