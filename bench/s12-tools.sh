#!/usr/bin/env bash
# S12: everyday tool speed on the image. Each metric runs N times per variant, cold (guest page
# cache dropped before each step) and warm. The Windows host cache can't be dropped without
# admin, so "cold" means guest-cold; see docs/methodology.md.
. "$(dirname "$0")/lib/host.sh"
N=${N:-5}; : > "$RAW/s12.jsonl"
for mode in cold warm; do
  # One untimed pass first, so the first warm sample is not left cold by the cold loop.
  [ "$mode" = warm ] && for v in "${VARIANTS[@]}"; do wx "$(distro $v)" root warm < "$REPO/bench/guest/s12.sh" >/dev/null; done
  for r in $(seq 1 "$N"); do for v in $(order "$r"); do
    wx "$(distro $v)" root "$mode" < "$REPO/bench/guest/s12.sh" | while read -r m ms rc; do
      rec s12 "$v" "${m}_${mode}_ms" "$ms" ms "$r" "rc=$rc"; done
  done; log "$mode run $r"; done
done
log "done"
