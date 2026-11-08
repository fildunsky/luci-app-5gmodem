#!/bin/sh
set -eu
exec python3 "$(dirname "$0")/check-readme-links.py" "$@"
