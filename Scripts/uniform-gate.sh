#!/usr/bin/env bash
# Basketball uniform gate: headless geometry checks, then an 8-view contact sheet at out/gate/<name>.png.
# Usage: Scripts/uniform-gate.sh [name] [hoops args, e.g. j.offset=0.05 ready=0.6 scale=1.5]
set -euo pipefail
cd "$(dirname "$0")/.."
name=${1:-sheet}; shift || true
swift build -c release --product humanhd 2>&1 | grep -E "error:|Build of" || true
.build/release/humanhd gate "$@"
mkdir -p out/gate
.build/release/humanhd hoops "out=out/gate/$name.png" "$@"
