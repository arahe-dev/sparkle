#!/usr/bin/env bash
# S10b: prove every variant holds the same system files, and record each variant's size at rest.
# Part of S10; split out so it can be re-run after a prototype fix.
. "$(dirname "$0")/lib/host.sh"
sed -i '/"metric":"\(manifest_[a-z_]*\|wsl_mounts\|vhdx_bytes\|footprint_bytes\)"/d' "$RAW/s10.jsonl"
log "equivalence: same system files in every variant"
for v in "${VARIANTS[@]}"; do
  wx "$(distro $v)" root "$BENCH_WSL" > "$BENCH/manifest-$v.txt" < "$REPO/bench/guest/manifest.sh"
  rec s10 "$v" manifest_meta "\"$(sed -n 's/^meta //p' "$BENCH/manifest-$v.txt")\"" text
  rec s10 "$v" manifest_content "\"$(sed -n 's/^content //p' "$BENCH/manifest-$v.txt")\"" text
  rec s10 "$v" manifest_entries "$(sed -n 's/^entries //p' "$BENCH/manifest-$v.txt")" count
  rec s10 "$v" wsl_mounts_under_usr "$(sed -n 's/^wsl_mounts //p' "$BENCH/manifest-$v.txt")" count
done
log "size at rest after first boot"
wsl.exe --shutdown; sleep 2
for v in "${VARIANTS[@]}"; do
  rec s10 "$v" vhdx_bytes "$(vhdx_bytes $v)" B
  rec s10 "$v" footprint_bytes "$(footprint $v)" B
done
log "done"; cat "$RAW/s10.jsonl"
