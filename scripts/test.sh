#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --scratch-path "${TMPDIR:-/tmp}/StatementManagerTests"
