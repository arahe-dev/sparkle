#!/usr/bin/env bash
# S18 fixtures: two packs from the S10 image.sqfs + seed.tar, with today's proto/stub scripts.
#   old - upper layer on the seed disk (as in S10-S17)
#   up  - upper layer in $BENCH/upper-up.img (sparse, made by s18-reclaim.sh)
# Re-runs replace both distros. Run s10-fixtures.sh first.
. "$(dirname "$0")/lib/host.sh"
T=/mnt/wsl/spb-s18seed
rm -f "$BENCH/upper-up.img"   # a fresh run starts from a new empty upper file
for v in old up; do
  wsl.exe --unregister "$(distro $v)" >/dev/null 2>&1 || true
  mkdir -p "$BENCH/distros/$v"
  # Unpack the seed, swap in the current stub scripts, set / to 0755, and (up) name the upper file.
  wx "$TOOL" root <<SH
set -e
rm -rf $T; mkdir -p $T/root; cd $T/root
tar --numeric-owner --xattrs --xattrs-include='*' -xpf $BENCH_WSL/seed.tar
cp $REPO_WSL/proto/stub/init.sh $REPO_WSL/proto/stub/prewarm.sh .sparkle/
chmod 755 .
rm -f .sparkle/upper-img
[ $v = up ] && echo $BENCH_WSL/upper-up.img > .sparkle/upper-img
tar --numeric-owner --xattrs --xattrs-include='*' -cpf $T/seed-$v.tar .
SH
  wsl.exe -d "$TOOL" -u root -- cat "$T/seed-$v.tar" |
    wsl.exe --import "$(distro $v)" "$BENCH_WIN\\distros\\$v" - --version 2
  log "imported $(distro $v)"
done
wx "$TOOL" root <<<"rm -rf $T"
