#!/usr/bin/env bash
# S16: failure modes. What happens when things go wrong, and does the pack recover?
#   concurrent_cold  - 4 terminals opened at once on a stopped distro (5 reps)
#   power_cut        - VM killed (wsl --shutdown) while dpkg is unpacking an apt install
#   image_missing    - the image file is gone (sparkle only): what does the user see?
#   export           - `wsl --export` (what users do for backups)
# Usage: s16-robust.sh [section...]   (default: all four)
. "$(dirname "$0")/lib/host.sh"
# Sections to run (default all). Re-running some replaces only their rows in raw/s16.jsonl.
SECTIONS=${*:-concurrent power_cut image_missing export}
want() { [[ " $SECTIONS " == *" $1 "* ]]; }
if [ $# -eq 0 ]; then : > "$RAW/s16.jsonl"; else
  touch "$RAW/s16.jsonl"
  for s in $SECTIONS; do grep -v "\"metric\":\"${s%%_*}_" "$RAW/s16.jsonl" > "$RAW/s16.tmp" || true; mv "$RAW/s16.tmp" "$RAW/s16.jsonl"; done
fi
probe() { wsl.exe -d "$(distro $1)" -u dev --cd / --exec /usr/bin/test -e /opt/ros/jazzy/setup.bash 2>/dev/null; }

if want concurrent; then
log "concurrent cold starts"
wsl.exe -d "$TOOL" -u root -- sleep 3600 & KEEP=$!; sleep 3
for rep in 1 2 3 4 5; do for v in "${VARIANTS[@]}"; do
  wsl.exe -t "$(distro $v)" >/dev/null 2>&1 || true
  ok=0; pids=(); for i in 1 2 3 4; do probe "$v" & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" && ok=$((ok+1)); done
  rec s16 "$v" concurrent_cold_ok "$ok" of4 "$rep"
done; done
kill $KEEP 2>/dev/null || true; wsl.exe -t "$TOOL" >/dev/null 2>&1 || true   # killing wsl.exe leaves the guest sleep running
fi

if want power_cut; then
log "power cut during apt install"
for v in "${VARIANTS[@]}"; do
  d=$(distro "$v")
  wx "$d" root "$BENCH_WSL" install < "$REPO/bench/guest/s14.sh" >/dev/null 2>&1 & job=$!
  # Cut only once dpkg is really running: copying the debs to RAM alone takes several seconds.
  # pgrep also matches apt's brief `dpkg --print-foreign-architectures`; the extra_* rows after
  # the reboot are the real proof the cut landed mid-unpack.
  t0=$(now_ms); seen=0
  while [ "$(since_ms "$t0")" -lt 90000 ]; do
    wsl.exe -d "$d" -u root --cd / --exec /usr/bin/pgrep -x dpkg >/dev/null 2>&1 && { seen=1; break; }
    sleep 0.5
  done
  sleep 1; at=$(since_ms "$t0"); wsl.exe --shutdown; wait "$job" || true
  rec s16 "$v" power_cut_dpkg_was_running "$seen" bool; rec s16 "$v" power_cut_at_ms "$at" ms
  boot=0; probe "$v" && boot=1; rec s16 "$v" power_cut_boots "$boot" bool
  wx "$d" root "$BENCH_WSL" "$REPO_WSL" < "$REPO/bench/guest/s16-after-cut.sh" |
    while read -r m val unit; do rec s16 "$v" "power_cut_$m" "$val" "$unit"; done
done
fi

if want image_missing; then
log "image missing (sparkle)"
wsl.exe --shutdown; mv "$BENCH/image.sqfs" "$BENCH/image.sqfs.away"
trap 'mv "$BENCH/image.sqfs.away" "$BENCH/image.sqfs" 2>/dev/null || true' EXIT   # never leave the image away
t0=$(now_ms); out=$(timeout 60 wsl.exe -d "$(distro sparkle)" 2>&1 </dev/null | tr -d '\r"\\' | grep -v '^$' | head -3 | tr '\n' ' ' || true)
rec s16 sparkle image_missing_message 0 text 0 "$out"; rec s16 sparkle image_missing_error_ms "$(since_ms $t0)" ms
sleep 7   # init.sh waits 5 s for the image before it logs IMAGE MISSING
log=$(timeout 60 wsl.exe -d "$(distro sparkle)" -u root --cd / --exec /.sparkle/bin/busybox tail -3 /.sparkle/boot.log 2>&1 </dev/null | tr -d '\r"\\' | tr '\n' ' ' | sed "s#$BENCH_WSL#<bench>#g" || true)   # no user paths in public data
rec s16 sparkle image_missing_bootlog 0 text 0 "$log"
wsl.exe --shutdown; mv "$BENCH/image.sqfs.away" "$BENCH/image.sqfs"
ok=0; probe sparkle && ok=1; rec s16 sparkle image_restored_boots "$ok" bool
fi

if want export; then
log "wsl --export"
for v in "${VARIANTS[@]}"; do
  t0=$(now_ms); n=$(wsl.exe --export "$(distro $v)" - 2>/dev/null | tar -tvf - 2>/dev/null | awk '{s+=$3; n++} END{print n, s}' || true)
  read -r entries bytes <<<"$n"
  rec s16 "$v" export_ms "$(since_ms $t0)" ms; rec s16 "$v" export_entries "${entries:-0}" count; rec s16 "$v" export_bytes "${bytes:-0}" B
done
fi
if [ $# -eq 0 ]; then wsl.exe --shutdown; fi   # a section re-run leaves the VM as it is
log "done"
