#!/usr/bin/env bash
# Run S12-S15 with the distros held open for the whole session, so WSL never restarts between
# steps (each VM restart re-attaches Hyper-V devices and refreshes File Explorer). S15 ends with
# one shutdown, which `wsl --manage --compact` needs.
. "$(dirname "$0")/lib/host.sh"
HOLD=(); for v in "${VARIANTS[@]}"; do wsl.exe -d "$(distro $v)" -u root -- sleep 14400 & HOLD+=($!); done
trap 'kill "${HOLD[@]}" 2>/dev/null || true' EXIT
sleep 3
for s in "$@"; do log "=== $s"; bash "$REPO/bench/$s.sh"; done
