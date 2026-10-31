#!/usr/bin/env bash
# S19: remove the cold-read cost. Image formats (squashfs 128K/1M/uncompressed, erofs lz4hc/
# uncompressed) against the same tree on ext4, all in one bench distro (see guest/s19-setup.sh);
# then prewarm.sh on the current format. Run guest/s19-build.sh in the tool distro first.
#   SPARKLE_BENCH_DIR=... s19-coldread.sh      (bench distro: $(distro s19), already imported)
. "$(dirname "$0")/lib/host.sh"
N=${N:-5}; D=${S19_DISTRO:-s19-bench}; PW="$REPO_WSL/proto/stub/prewarm.sh"
: > "$RAW/s19.jsonl"
while read -r v m val; do rec s19 "$v" "$m" "$val" "${m##*_}" 0; done < <(grep -E '_bytes|build_ms' "$BENCH/build.log")
wx "$D" root "$BENCH_WSL" < "$REPO/bench/guest/s19-setup.sh" >&2
run() { local mode=$1; shift; VARIANTS=("$@")
  [ "$mode" = warm ] && for v in "$@"; do wx "$D" root warm "$v" "$PW" < "$REPO/bench/guest/s19.sh" >/dev/null; done
  for r in $(seq 1 "$N"); do for v in $(order "$r"); do
    wx "$D" root "$mode" "$v" "$PW" < "$REPO/bench/guest/s19.sh" | while read -r m val rc; do
      case $m in *_mb) u=MB ;; *) u=ms ;; esac
      rec s19 "$v" "${m}_${mode}" "$val" "$u" "$r" "rc=$rc"; done
  done; log "$mode run $r"; done; }
run cold plain sq128 sq1m sqraw erolz4 eroraw sqraw_direct
run warm plain sq128 sq1m sqraw erolz4 eroraw sqraw_direct
run prew sq128 eroraw
run race sq128 eroraw
log done
