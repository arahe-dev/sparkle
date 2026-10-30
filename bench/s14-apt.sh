#!/usr/bin/env bash
# S14: install and remove a realistic package set (mesa-utils, scipy, ripgrep, jq, htop, gdb and
# their dependencies) from local .debs. Measures time, the space the guest sees, and how much
# the Windows-side disk file grows and gives back.
. "$(dirname "$0")/lib/host.sh"
N=${N:-3}; : > "$RAW/s14.jsonl"
if [ ! -f "$BENCH/lists.tar" ]; then
  log "prep: apt update + download (network, once, in plain)"
  wx "$(distro plain)" root "$BENCH_WSL" < "$REPO/bench/guest/s14-prep.sh" | while read -r m val; do
    rec s14 plain "$m" "$val" "$( [ "${m##*_}" = ms ] && echo ms || echo count)"; done
fi
for r in $(seq 1 "$N"); do for v in $(order "$r"); do
  for act in install remove; do
    before=$(vhdx_bytes "$v")
    wx "$(distro $v)" root "$BENCH_WSL" "$act" < "$REPO/bench/guest/s14.sh" | while read -r m val rc; do
      rec s14 "$v" "$m" "$val" "$( [ "${m##*_}" = ms ] && echo ms || echo B)" "$r" "rc=$rc"; done
    rec s14 "$v" "${act}_vhdx_delta_bytes" "$(( $(vhdx_bytes "$v") - before ))" B "$r"
  done
done; log "run $r"; done
log "done"
