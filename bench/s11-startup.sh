#!/usr/bin/env bash
# S11: how long until a command runs. Three starts, N runs each, variants interleaved.
#   vm_cold     - after `wsl --shutdown`: VM boot + distro boot (+ image mount for sparkle)
#   distro_cold - after `wsl -t <distro>` with the VM still up: the common "open a terminal" case
#   warm        - the distro is already running
#   login_shell - warm `bash -l -c true`: profile scripts incl. sourcing ROS setup.bash
# The probe `test -e /opt/ros/jazzy/setup.bash` fails if the image is not mounted, so every
# timing also checks the pack booted correctly.
. "$(dirname "$0")/lib/host.sh"
N=${N:-10}; : > "$RAW/s11.jsonl"
probe() { wsl.exe -d "$(distro $1)" -u dev --cd / --exec /usr/bin/test -e "$PROBE" 2>/dev/null; }
timed() { local v=$1 m=$2 r=$3 t0 rc=0; t0=$(now_ms); probe "$v" || rc=$?; rec s11 "$v" "$m" "$(since_ms $t0)" ms "$r" "rc=$rc"; }

# SPARKLE_NO_SHUTDOWN=1 skips vm_cold: it needs `wsl --shutdown`.
[ -z "${SPARKLE_NO_SHUTDOWN:-}" ] && for r in $(seq 1 "$N"); do for v in $(order "$r"); do
  wsl.exe --shutdown; timed "$v" vm_cold_ms "$r"; done; log "vm_cold run $r"; done

stop_all; wsl.exe -d "$TOOL" -u root -- sleep 3600 & KEEP=$!; sleep 3
for r in $(seq 1 "$N"); do for v in $(order "$r"); do
  wsl.exe -t "$(distro $v)" >/dev/null 2>&1 || true; timed "$v" distro_cold_ms "$r"; done; log "distro_cold run $r"; done

declare -a HOLD=()
for v in "${VARIANTS[@]}"; do wsl.exe -d "$(distro $v)" -u dev -- sleep 3600 & HOLD+=($!); done; sleep 3
for r in $(seq 1 "$N"); do for v in $(order "$r"); do
  timed "$v" warm_ms "$r"
  t0=$(now_ms); rc=0; wsl.exe -d "$(distro $v)" -u dev --cd / --exec /bin/bash -l -c true 2>/dev/null || rc=$?
  rec s11 "$v" login_shell_ms "$(since_ms $t0)" ms "$r" "rc=$rc"
done; done
kill "${HOLD[@]}" $KEEP 2>/dev/null || true; stop_all
log "done"
