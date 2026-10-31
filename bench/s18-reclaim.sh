#!/usr/bin/env bash
# S18: does reset give the space back? Two packs from the same image.sqfs + seed.tar:
#   old - upper layer on the seed disk (as in S10-S17); reset = wipe the upper dirs in place
#   up  - upper layer in its own sparse ext4 file next to the image (proto/stub/init.sh,
#         /.sparkle/upper-img); reset = delete that file and make a new empty sparse one
# Footprint = image.sqfs + seed ext4.vhdx + upper file (allocated bytes, not apparent size).
# Only `wsl -t` of these two distros; never --shutdown.
. "$(dirname "$0")/lib/host.sh"
VARIANTS=(old up); N=${N:-5}
: > "$RAW/s18.jsonl"
UP=$BENCH/upper-up.img; UP_SIZE=${UP_SIZE:-68719476736}   # 64 GiB apparent, sparse
alloc() { [ -f "$1" ] && du -B1 "$1" | cut -f1 || echo 0; }
mkupper() { rm -f "$UP"; : > "$UP"; local w; w=$(cygpath -w "$UP")
  fsutil sparse setflag "$w" >/dev/null && fsutil file seteof "$w" "$UP_SIZE" >/dev/null; }
vhdx() { stat -c %s "$BENCH/distros/$1/ext4.vhdx"; }
img() { stat -c %s "$BENCH/image.sqfs"; }
foot() { local u=0; [ "$1" = up ] && u=$(alloc "$UP"); echo $(( $(img) + $(vhdx $1) + u )); }
snap() { # <variant> <stage>
  rec s18 "$1" "footprint_bytes_$2" "$(foot $1)" B; rec s18 "$1" "vhdx_bytes_$2" "$(vhdx $1)" B
  [ "$1" = up ] && rec s18 up "upper_alloc_bytes_$2" "$(alloc "$UP")" B; return 0; }
boot() { wsl.exe -d "$(distro $1)" -u dev --cd / --exec /usr/bin/test -e /opt/ros/jazzy/setup.bash; }
reset() { # <variant>: what `sparkle reset` would do
  if [ "$1" = old ]; then wx "$(distro old)" root <<<"touch /.sparkle/reset"; wsl.exe -t "$(distro old)" >/dev/null
  else wsl.exe -t "$(distro up)" >/dev/null; mkupper; fi
  local t0; t0=$(now_ms); boot "$1"; rec s18 "$1" reset_boot_ms "$(since_ms $t0)" ms; }
check() { # <variant> <stage>
  wx "$(distro $1)" root "$BENCH_WSL" < "$REPO/bench/guest/s18-check.sh" | while read -r m val; do
    rec s18 "$1" "${m}_$2" "$val" "$( [ "${m##*_}" = bytes ] && echo B || echo count)"; done; }

for v in "${VARIANTS[@]}"; do wsl.exe -t "$(distro $v)" >/dev/null 2>&1 || true; done
[ -f "$UP" ] || mkupper
for v in "${VARIANTS[@]}"; do boot $v; snap $v fresh; check $v fresh; done
for round in 1 2; do for v in $(order $round); do
  wx "$(distro $v)" root "$BENCH_WSL" install < "$REPO/bench/guest/s14.sh" | while read -r m val rc; do
    rec s18 "$v" "$m" "$val" "$( [ "${m##*_}" = ms ] && echo ms || echo count)" "$round" "rc=$rc"; done
  snap $v "installed$round"
  reset $v; snap $v "reset$round"; check $v "reset$round"
done; log "round $round"; done

log "startup: wsl -t then first command, interleaved (N=$N)"
for r in $(seq 1 "$N"); do for v in $(order $r); do
  wsl.exe -t "$(distro $v)" >/dev/null; t0=$(now_ms); boot $v; rec s18 "$v" startup_ms "$(since_ms $t0)" ms "$r"
done; done

log "seed disk: compact, then fstrim + compact (distro stopped, VM left running)"
for v in "${VARIANTS[@]}"; do
  wsl.exe -t "$(distro $v)" >/dev/null; rc=0; wsl.exe --manage "$(distro $v)" --compact >/dev/null 2>&1 || rc=$?
  rec s18 "$v" vhdx_bytes_compact "$(vhdx $v)" B 0 "rc=$rc"
  t=$(wx "$(distro $v)" root <<<"fstrim -v / 2>&1 | tail -1"); log "$v fstrim: $t"
  wsl.exe -t "$(distro $v)" >/dev/null; rc=0; wsl.exe --manage "$(distro $v)" --compact >/dev/null 2>&1 || rc=$?
  rec s18 "$v" vhdx_bytes_fstrim_compact "$(vhdx $v)" B 0 "rc=$rc"
  rec s18 "$v" footprint_bytes_fstrim_compact "$(foot $v)" B 0 "rc=$rc"
done
log "done"
