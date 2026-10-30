#!/usr/bin/env bash
# S16: failure modes. What happens when things go wrong, and does the pack recover?
#   concurrent_cold  - 4 terminals opened at once on a stopped distro (5 reps)
#   power_cut        - VM killed (wsl --shutdown) in the middle of dpkg -i
#   image_missing    - the image file is gone (sparkle only): what does the user see?
#   export           - `wsl --export` (what users do for backups)
. "$(dirname "$0")/lib/host.sh"
: > "$RAW/s16.jsonl"
probe() { wsl.exe -d "$(distro $1)" -u dev --cd / --exec /usr/bin/test -e /opt/ros/jazzy/setup.bash 2>/dev/null; }

log "concurrent cold starts"
wsl.exe -d "$TOOL" -u root -- sleep 3600 & KEEP=$!; sleep 3
for rep in 1 2 3 4 5; do for v in "${VARIANTS[@]}"; do
  wsl.exe -t "$(distro $v)" >/dev/null 2>&1 || true
  ok=0; pids=(); for i in 1 2 3 4; do probe "$v" & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" && ok=$((ok+1)); done
  rec s16 "$v" concurrent_cold_ok "$ok" of4 "$rep"
done; done
kill $KEEP 2>/dev/null || true

log "power cut during dpkg -i"
for v in "${VARIANTS[@]}"; do
  wx "$(distro $v)" root "$BENCH_WSL" install < "$REPO/bench/guest/s14.sh" >/dev/null 2>&1 &
  sleep 6; wsl.exe --shutdown; wait || true
  boot=0; probe "$v" && boot=1
  res=$(wx "$(distro $v)" root "$BENCH_WSL" <<'SH'
a=$(dpkg --audit 2>&1 | grep -c .); dpkg --configure -a >/dev/null 2>&1; c=$?
P=$(for f in $1/debs/*.deb; do dpkg-deb -f $f Package; done); dpkg -P $P >/dev/null 2>&1; p=$?
echo "$a $c $p $(dpkg -l | grep -c '^ii')"
SH
)
  read -r audit cfg purge ndpkg <<<"$res"
  rec s16 "$v" power_cut_boots "$boot" bool; rec s16 "$v" power_cut_audit_lines "$audit" count
  rec s16 "$v" power_cut_configure_rc "$cfg" rc; rec s16 "$v" power_cut_cleanup_rc "$purge" rc
  rec s16 "$v" power_cut_dpkg_after "$ndpkg" count
done

log "image missing (sparkle)"
wsl.exe --shutdown; mv "$BENCH/image.sqfs" "$BENCH/image.sqfs.away"
out=$(wsl.exe -d "$(distro sparkle)" 2>&1 </dev/null | tr -d '\r' | grep -v '^$' | head -3 | tr '\n' ' ' | tr -d '"\'); rc=$?
rec s16 sparkle image_missing_message 0 text 0 "$out"
log=$(wsl.exe -d "$(distro sparkle)" -u root --cd / --exec /.sparkle/bin/busybox tail -2 /.sparkle/boot.log 2>&1 | tr -d '\r"\' | tr '\n' ' ')
rec s16 sparkle image_missing_bootlog 0 text 0 "$log"
wsl.exe --shutdown; mv "$BENCH/image.sqfs.away" "$BENCH/image.sqfs"
ok=0; probe sparkle && ok=1; rec s16 sparkle image_restored_boots "$ok" bool

log "wsl --export"
for v in "${VARIANTS[@]}"; do
  t0=$(now_ms); n=$(wsl.exe --export "$(distro $v)" - 2>/dev/null | tar -tvf - 2>/dev/null | awk '{s+=$3; n++} END{print n, s}')
  read -r entries bytes <<<"$n"
  rec s16 "$v" export_ms "$(since_ms $t0)" ms; rec s16 "$v" export_entries "${entries:-0}" count; rec s16 "$v" export_bytes "${bytes:-0}" B
done
wsl.exe --shutdown; log "done"
