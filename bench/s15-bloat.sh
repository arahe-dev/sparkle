#!/usr/bin/env bash
# S15: disk growth over repeated real use, then what compaction and reset give back.
# Each round installs packages, builds and runs a workspace, then cleans up like a tidy user.
# A tidy user leaves nothing behind, so any growth is space the disk file does not give back.
. "$(dirname "$0")/lib/host.sh"
R=${R:-5}; : > "$RAW/s15.jsonl"
for v in "${VARIANTS[@]}"; do rec s15 "$v" footprint_bytes "$(footprint $v)" B 0; rec s15 "$v" vhdx_bytes "$(vhdx_bytes $v)" B 0; done
for r in $(seq 1 "$R"); do for v in $(order "$r"); do
  wx "$(distro $v)" root "$BENCH_WSL" < "$REPO/bench/guest/s15-round.sh" | while read -r m val; do
    rec s15 "$v" "$m" "$val" "$( [ "${m##*_}" = mb ] && echo MB || echo B)" "$r"; done
  rec s15 "$v" vhdx_bytes "$(vhdx_bytes $v)" B "$r"; rec s15 "$v" footprint_bytes "$(footprint $v)" B "$r"
done; log "round $r"; done

log "reset (sparkle): leave packages installed, then reset; restarts only the sparkle distro"
wx "$(distro sparkle)" root "$BENCH_WSL" install < "$REPO/bench/guest/s14.sh" >/dev/null
rec s15 sparkle footprint_before_reset_bytes "$(footprint sparkle)" B
n_dirty=$(wx "$(distro sparkle)" root <<<"dpkg -l | grep -c '^ii'")
wx "$(distro sparkle)" root <<<"touch /.sparkle/reset"
wsl.exe -t "$(distro sparkle)"
t0=$(now_ms); wsl.exe -d "$(distro sparkle)" -u dev --cd / --exec /usr/bin/test -e /opt/ros/jazzy/setup.bash
rec s15 sparkle reset_boot_ms "$(since_ms $t0)" ms
n_clean=$(wx "$(distro sparkle)" root <<<"dpkg -l | grep -c '^ii'")
upper=$(wx "$(distro sparkle)" root <<<"du -sb /.sparkle/upper | cut -f1")
rec s15 sparkle dpkg_before_reset "$n_dirty" count; rec s15 sparkle dpkg_after_reset "$n_clean" count
rec s15 sparkle upper_after_reset_bytes "$upper" B

log "compact all (one shutdown; what a user can do by hand today: wsl --manage <d> --compact)"
wsl.exe --shutdown
for v in "${VARIANTS[@]}"; do
  t0=$(now_ms); wsl.exe --manage "$(distro $v)" --compact >/dev/null 2>&1 || true
  rec s15 "$v" compact_ms "$(since_ms $t0)" ms; rec s15 "$v" vhdx_after_compact_bytes "$(vhdx_bytes $v)" B
  rec s15 "$v" footprint_after_compact_bytes "$(footprint $v)" B
done
log "done"
