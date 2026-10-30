#!/usr/bin/env bash
# S13: clean colcon build of a ROS 2 workspace (on the writable disk in every variant).
. "$(dirname "$0")/lib/host.sh"
N=${N:-3}; : > "$RAW/s13.jsonl"
for v in "${VARIANTS[@]}"; do wx "$(distro $v)" dev setup < "$REPO/bench/guest/s13.sh"; done
for r in $(seq 1 "$N"); do for v in $(order "$r"); do
  before=$(vhdx_bytes "$v")
  wx "$(distro $v)" dev build < "$REPO/bench/guest/s13.sh" | while read -r m val; do
    rec s13 "$v" "$m" "$val" "$( [ "${m##*_}" = ms ] && echo ms || echo MB)" "$r"; done
  rec s13 "$v" vhdx_growth_bytes "$(( $(vhdx_bytes "$v") - before ))" B "$r"
done; log "run $r"; done
log "done"
