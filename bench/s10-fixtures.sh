#!/usr/bin/env bash
# S10: build the three variants from one image and prove they hold identical system files.
#   plain   - the image imported as a normal WSL distro (what `docker export | wsl --import` gives you)
#   tuned   - plain + Sparkle's tmpfs volatile paths via /etc/fstab (what a careful user can do alone)
#   sparkle - the same files as a read-only squashfs image on NTFS + a small writable seed disk
# Input: an OCI/docker image tarball (default: ros:jazzy-ros-base, linux/amd64).
. "$(dirname "$0")/lib/host.sh"
IMAGE_TAR=${1:?usage: s10-fixtures.sh <image.tar> [crane.exe] [busybox]}
CRANE=${2:-crane.exe}
BB=${3:-$BENCH/busybox}
T=${SPARKLE_TREE:-/mnt/wsl/spb-tree}   # in the helper distro; parallel sessions need their own
[ -f "$RAW/s10.jsonl" ] || : > "$RAW/s10.jsonl"
machine_facts

# Re-runs skip variants that already exist; unregister one to rebuild it.
exists() { wsl.exe -l -q 2>/dev/null | tr -d '\0\r' | grep -qx "$(distro $1)"; }
[ -f "$BB" ] || { echo "need a static busybox at $BB (see docs/methodology.md)"; exit 1; }
rec s10 all busybox_sha256 "\"$(sha256sum "$BB" | cut -c1-64)\"" text

log "keep the helper distro alive; extract the image into tmpfs"
wsl.exe -d "$TOOL" -u root -- sleep 7200 & KEEP=$!
trap 'kill $KEEP 2>/dev/null || true' EXIT
wx "$TOOL" root <<SH
mkdir -p $T; mountpoint -q $T || mount -t tmpfs -o size=8g tmpfs $T; rm -rf $T/* $T/.[!.]* 2>/dev/null || true
SH
t0=$(now_ms)
"$CRANE" export - - < "$IMAGE_TAR" | wsl.exe -d "$TOOL" -u root -- tar -xpf - -C $T --numeric-owner --xattrs --xattrs-include='*'
rec s10 all flatten_extract_ms "$(since_ms $t0)" ms
wx "$TOOL" root <<SH
sh $REPO_WSL/proto/build-fixtures.sh setup $T $BENCH_WSL
du -sm --apparent-size $T | cut -f1 > $BENCH_WSL/tree_mb
SH
rec s10 all tree_apparent_mb "$(cat "$BENCH/tree_mb")" MB

import_stream() { # <variant>: tar the tree straight into wsl --import, no temp file
  local v=$1 t0; exists "$v" && { log "$(distro $v) exists, skipped"; return; }
  mkdir -p "$BENCH/distros/$v"; t0=$(now_ms)
  wsl.exe -d "$TOOL" -u root -- tar -C $T --numeric-owner --xattrs --xattrs-include='*' -cpf - . \
    | wsl.exe --import "$(distro $v)" "$(cygpath -w "$BENCH/distros/$v")" - --version 2
  rec s10 "$v" import_ms "$(since_ms $t0)" ms; }

log "plain"; import_stream plain
log "tuned"; wx "$TOOL" root <<<"sh $REPO_WSL/proto/build-fixtures.sh tuned $T $BENCH_WSL"; import_stream tuned
log "sparkle: image + seed"
t0=$(now_ms)
out=$(wx "$TOOL" root <<<"sh $REPO_WSL/proto/build-fixtures.sh sparkle $T $BENCH_WSL $(to_wsl "$BB")")
rec s10 sparkle build_image_and_seed_ms "$(since_ms $t0)" ms; echo "$out"
t0=$(now_ms); mkdir -p "$BENCH/distros/sparkle"
wsl.exe --import "$(distro sparkle)" "$(cygpath -w "$BENCH/distros/sparkle")" "$(cygpath -w "$BENCH/seed.tar")" --version 2
rec s10 sparkle import_ms "$(since_ms $t0)" ms
rec s10 sparkle image_bytes "$(stat -c %s "$BENCH/image.sqfs")" B
rec s10 sparkle seed_tar_bytes "$(stat -c %s "$BENCH/seed.tar")" B
wx "$TOOL" root <<<"umount $T"
kill $KEEP 2>/dev/null || true

bash "$REPO/bench/s10b-equivalence.sh"
