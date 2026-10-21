#!/usr/bin/env bash
# Security checks for Show My Copy. The checks live in check_security.py (python3 ships with
# the Xcode command line tools); this wrapper keeps the old entry point working.
#   scripts/check_security.sh            project settings, entitlements files and sources
#   scripts/check_security.sh path/App   also the signed app and all code nested in it
set -euo pipefail
exec python3 -I "$(dirname "$0")/check_security.py" "$@"
