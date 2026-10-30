#!/usr/bin/env bash
# Run every benchmark in order, then regenerate the summary. About 60-90 minutes.
#   bash bench/run-all.sh <image.tar> [crane.exe]
# Order matters: S17 and S15 use the packages S14 downloads, S15 the workspace from S13.
# S15 (disk growth) and S16 (power cuts) change the distros, so they run last.
set -euo pipefail
cd "$(dirname "$0")/.."
bash bench/s10-fixtures.sh "$@"
for s in s11-startup s12-tools s13-build s14-apt s17-compat s15-bloat s16-robust; do
  echo "=== $s"; bash "bench/$s.sh"
done
python bench/summarize.py
