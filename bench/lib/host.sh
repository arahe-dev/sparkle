# Host-side helpers for the benchmark scripts. Git Bash on Windows; source this file.
set -euo pipefail
export MSYS_NO_PATHCONV=1 WSL_UTF8=1

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BENCH=$(cygpath -u "${SPARKLE_BENCH_DIR:-$USERPROFILE/sparkle-bench}")
BENCH_WIN=$(cygpath -w "$BENCH")
to_wsl() { local p; p=$(cygpath -m "$1"); echo "/mnt/$(echo "${p:0:1}" | tr A-Z a-z)${p:2}"; }
BENCH_WSL=$(to_wsl "$BENCH")
REPO_WSL=$(to_wsl "$REPO")
RAW=${SPARKLE_RAW_DIR:-$REPO/bench/results/raw}   # parallel sessions: give each its own
TOOL=${SPARKLE_TOOL_DISTRO:-sparkle-s1-ours2}   # any distro with mksquashfs >= 4.6
VARIANTS=(plain tuned sparkle)
# Image profile. Defaults are the ROS image; other images set these (see docs/methodology.md).
PROBE=${SPARKLE_PROBE:-/opt/ros/jazzy/setup.bash}   # a file that exists only once the image is mounted
GUEST=${SPARKLE_GUEST:-}   # guest-script suffix: bench/guest/s12$GUEST.sh, s17$GUEST.sh
# SPARKLE_NO_SHUTDOWN=1: never restart the shared VM; restart only our own distros (wsl -t).
stop_all() { local v; if [ -n "${SPARKLE_NO_SHUTDOWN:-}" ]; then for v in "${VARIANTS[@]}"; do wsl.exe -t "$(distro $v)" >/dev/null 2>&1 || true; done; else wsl.exe --shutdown; fi; }
mkdir -p "$RAW" "$BENCH"

# Parallel sessions on one PC must not share distros: set SPARKLE_PREFIX (e.g. spb18).
distro() { echo "${SPARKLE_PREFIX:-spb}-$1"; }
now_ms() { date +%s%3N; }
since_ms() { echo $(( $(now_ms) - $1 )); }

# Run the script on stdin inside a distro: wx <distro> <user> [args...]. Commands go through
# stdin, never the command line: wsl.exe mangles `$` and quoting.
# The profile is sourced by hand: a login shell would run ~/.bash_logout, whose clear_console
# fails without a terminal and turns every exit code into 1.
wx() { local d=$1 u=$2; shift 2
  { echo '. /etc/profile >/dev/null 2>&1; cd ~'; cat; } |
    wsl.exe -d "$d" -u "$u" --cd / -- bash -s -- "$@" 2> >(grep -v 'Failed to translate' >&2); }

# Variant order rotates each run so drift (thermals, background work) hits every variant.
order() { local r=$1 n=${#VARIANTS[@]} i; for i in $(seq 0 $((n-1))); do echo "${VARIANTS[$(( (i + r) % n ))]}"; done; }

# rec <test> <variant> <metric> <value> <unit> [run] [note]
rec() { printf '{"test":"%s","variant":"%s","metric":"%s","value":%s,"unit":"%s","run":%s,"note":"%s"}\n' \
  "$1" "$2" "$3" "$4" "$5" "${6:-0}" "${7:-}" >> "$RAW/$1.jsonl"; }

vhdx_bytes() { stat -c %s "$BENCH/distros/$1/ext4.vhdx"; }
# Total on-disk footprint: the distro disk, plus the image file for sparkle.
footprint() { local b; b=$(vhdx_bytes "$1"); [ "$1" = sparkle ] && b=$((b + $(stat -c %s "$BENCH/image.sqfs"))); echo "$b"; }
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

# Machine facts for the results header.
machine_facts() {
  { echo "date: $(date -u +%FT%TZ)"
    wsl.exe --version 2>/dev/null | tr -d '\0\r' | head -3
    powershell.exe -NoProfile -Command "(Get-CimInstance Win32_Processor).Name; '{0:N0} GB RAM' -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB); (Get-CimInstance Win32_OperatingSystem).Caption; (Get-PhysicalDisk | Select -First 1).FriendlyName" 2>/dev/null | tr -d '\r'
  } > "$(dirname "$RAW")/machine.txt"; }
