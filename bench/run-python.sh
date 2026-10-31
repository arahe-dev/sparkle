#!/usr/bin/env bash
# Second image: run the image-generic benchmarks on python:3.12-bookworm (Debian, no ROS) on a
# VM shared with other work: no `wsl --shutdown` anywhere, own prefix/dirs/tree path.
#   bash bench/run-python.sh <image.tar> <crane.exe>
set -euo pipefail
cd "$(dirname "$0")/.."
export SPARKLE_PREFIX=${SPARKLE_PREFIX:-spb2i} SPARKLE_BENCH_DIR=${SPARKLE_BENCH_DIR:-$USERPROFILE/sparkle-bench-2i} \
  SPARKLE_RAW_DIR=${SPARKLE_RAW_DIR:-$PWD/bench/results-python/raw} SPARKLE_TREE=${SPARKLE_TREE:-/mnt/wsl/spb2i-tree} \
  SPARKLE_PROBE=/usr/local/bin/python3 SPARKLE_GUEST=-python SPARKLE_NO_SHUTDOWN=1 N=${N:-5}
bash bench/s10-fixtures.sh "$1" "$2" "$SPARKLE_BENCH_DIR/busybox"
bash bench/run-quiet.sh s17-compat s12-tools
bash bench/s11-startup.sh
bash bench/s20-restore.sh
python bench/summarize.py
