#!/bin/sh
# Compatibility entry point; Python is the single SQL suite implementation.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON=python3
command -v python3 >/dev/null 2>&1 || PYTHON=python
exec "$PYTHON" "$root/tests/sql_tests.py" "$@"
