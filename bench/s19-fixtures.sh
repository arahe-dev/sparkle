#!/usr/bin/env bash
# S19 fixtures: image variants cut from the S10 image, plus the bench distro that mounts them.
#   SPARKLE_BENCH_DIR=<s19 dir> S10_BENCH=<dir holding the S10 image.sqfs + seed.tar> s19-fixtures.sh
# Writes $BENCH/build.log (sizes, build times) and imports $S19_DISTRO from the S10 seed.
# Loads erofs.ko in the helper distro: one kernel serves every distro, so the module is then
# loaded for the bench distro too (a pack can't load it itself yet; see S19 in docs/results.md).
. "$(dirname "$0")/lib/host.sh"
S10=$(cygpath -u "${S10_BENCH:-$USERPROFILE/sparkle-bench}"); S10_WSL=$(to_wsl "$S10")
D=${S19_DISTRO:-s19-bench}
wsl.exe -d "$TOOL" -u root -- sleep 7200 & KEEP=$!   # keeps the tree in /mnt/wsl alive for setup
trap 'kill $KEEP 2>/dev/null || true' EXIT
sleep 3
# The helper has no kmod; WSL mounts the kernel's modules at /usr/lib/modules/<kver>.
wx "$TOOL" root "$S10_WSL/busybox" <<'SH'
grep -qw erofs /proc/filesystems || {
  BB=$1; k=$(find /usr/lib/modules/$(uname -r) -name 'erofs.ko*' | head -1)
  case $k in *.xz) $BB xzcat "$k" > /tmp/erofs.ko ;; *.gz) $BB zcat "$k" > /tmp/erofs.ko ;; *) cp "$k" /tmp/erofs.ko ;; esac
  $BB insmod /tmp/erofs.ko; }
grep -qw erofs /proc/filesystems && echo "erofs loaded" || { echo "erofs NOT loaded"; exit 1; }
SH
wx "$TOOL" root "$S10_WSL/image.sqfs" "$BENCH_WSL" < "$REPO/bench/guest/s19-build.sh" | tee "$BENCH/build.log"
wsl.exe --unregister "$D" >/dev/null 2>&1 || true
mkdir -p "$BENCH/distros/s19"
wsl.exe --import "$D" "$BENCH_WIN\distros\s19" "$(cygpath -w "$S10/seed.tar")" --version 2
