#!/usr/bin/env bash
# S20: backup and restore with `wsl --export` / `wsl --import` (S16 only timed the export).
#   1. export plain and sparkle to tar files, import each as a new distro <prefix>-restore-<v>
#   2. boot each restored distro: does the probe file exist (image mounted) and do tools run?
#   3. sparkle only: point the restored pack's /.sparkle/image at a folder with no image (what a
#      restore onto another PC, or after moving the image, looks like), boot, record what happens;
#      then point it at a copy of the image in a new folder and boot again.
# Creates <prefix>-restore-plain/-sparkle; never unregisters anything (print the command instead).
#   s20-restore.sh [restore] [move]   re-runs only those sections and replaces only their rows
. "$(dirname "$0")/lib/host.sh"
SECTIONS=${*:-restore move}
want() { [[ " $SECTIONS " == *" $1 "* ]]; }
touch "$RAW/s20.jsonl"
want move && sed -i '/"metric":"\(moved\|repointed\)_/d' "$RAW/s20.jsonl"
CHECK=${SPARKLE_RESTORE_CHECK:-python3 --version}   # a tool from the image, run as dev
X="$BENCH/export"; mkdir -p "$X"
exists() { wsl.exe -l -q 2>/dev/null | tr -d '\0\r' | grep -qx "$1"; }
probe() { local rc=0; timeout 90 wsl.exe -d "$1" -u dev --cd / --exec /usr/bin/test -e "$PROBE" >/dev/null 2>&1 </dev/null || rc=$?; echo $rc; }
bootlog() { timeout 60 wsl.exe -d "$1" -u root --cd / --exec /.sparkle/bin/busybox tail -2 /.sparkle/boot.log 2>&1 </dev/null \
  | tr -d '\r"\' | tr '\n' ' ' | sed "s#$BENCH_WSL#<bench>#g" || true; }   # no user paths in public data
setimg() { # <distro> <wsl path>: rewrite /.sparkle/image with busybox (works with /usr unmounted)
  echo "$2" | timeout 60 wsl.exe -d "$1" -u root --cd / --exec /.sparkle/bin/busybox sh -c '/.sparkle/bin/busybox cat > /.sparkle/image'; }

want restore && for v in ${S20_VARIANTS:-plain sparkle}; do
  src=$(distro $v) dst=$(distro ${S20_NAME:-restore}-$v)   # S20_NAME: a fresh name for a redo
  sed -i "/\"variant\":\"$v\",\"metric\":\"\(export\|import\|restored\)_/d" "$RAW/s20.jsonl"
  wsl.exe -t "$src" >/dev/null 2>&1 || true
  # Streamed: export piped straight into import, so no backup tar lands on the (shared, nearly
  # full) disk. A real backup writes the same stream to a file: wsl --export <d> <file.tar>.
  if exists "$dst"; then log "$dst exists, import skipped; to redo: wsl --unregister $dst"
    t0=$(now_ms); n=$(wsl.exe --export "$src" - | wc -c)
    rec s20 "$v" export_ms "$(since_ms $t0)" ms; rec s20 "$v" export_tar_bytes "$n" B
  else
    mkdir -p "$BENCH/distros/${S20_NAME:-restore}-$v"; t0=$(now_ms)
    wsl.exe --export "$src" - | tee >(wc -c > "$X/$v.bytes") | wsl.exe --import "$dst" "$(cygpath -w "$BENCH/distros/${S20_NAME:-restore}-$v")" - --version 2
    rec s20 "$v" export_import_ms "$(since_ms $t0)" ms; sleep 1; rec s20 "$v" export_tar_bytes "$(cat "$X/$v.bytes")" B
  fi
  t0=$(now_ms); rc=$(probe "$dst"); rec s20 "$v" restored_boot_probe_rc "$rc" rc 0 "first boot of the restored distro"
  rec s20 "$v" restored_boot_ms "$(since_ms $t0)" ms
  out=$(timeout 60 wsl.exe -d "$dst" -u dev --cd / -- sh -c "$CHECK" 2>&1 </dev/null | tr -d '\r"\' | head -1 || true)
  rec s20 "$v" restored_tool "$( [ -n "$out" ] && [ "$rc" = 0 ] && echo 1 || echo 0)" pass 0 "$out"
  u=$(wsl.exe -d "$dst" --cd / --exec /usr/bin/whoami 2>/dev/null </dev/null | tr -d '\r' || true)
  rec s20 "$v" restored_default_user "$( [ "$u" = dev ] && echo 1 || echo 0)" pass 0 "$u"
done

d=$(distro restore-sparkle)
if want move; then
rec s20 sparkle moved_original_image_path 0 text 0 "$(wsl.exe -d "$d" -u root --exec /.sparkle/bin/busybox cat /.sparkle/image 2>/dev/null | tr -d '\r' | sed "s#$BENCH_WSL#<bench>#g")"
log "image not where the pack expects it"
setimg "$d" "$BENCH_WSL/gone/image.sqfs"; wsl.exe -t "$d" >/dev/null 2>&1 || true
t0=$(now_ms); rc=$(probe "$d"); rec s20 sparkle moved_image_probe_rc "$rc" rc 0 "image path points at a folder with no image"
rec s20 sparkle moved_image_boot_ms "$(since_ms $t0)" ms
sleep 6   # boot waits up to 5 s for the image before it logs IMAGE MISSING
rec s20 sparkle moved_image_bootlog 0 text 0 "$(bootlog "$d")"
log "fix: copy the image to a new folder and write that path into /.sparkle/image"
[ -f "$BENCH/moved/image.sqfs" ] || { mkdir -p "$BENCH/moved"; cp "$BENCH/image.sqfs" "$BENCH/moved/image.sqfs"; }
setimg "$d" "$BENCH_WSL/moved/image.sqfs"; wsl.exe -t "$d" >/dev/null 2>&1 || true
t0=$(now_ms); rc=$(probe "$d"); rec s20 sparkle repointed_probe_rc "$rc" rc 0 "after writing the new path into /.sparkle/image"
rec s20 sparkle repointed_boot_ms "$(since_ms $t0)" ms
out=$(timeout 60 wsl.exe -d "$d" -u dev --cd / -- sh -c "$CHECK" 2>&1 </dev/null | tr -d '\r"\' | head -1 || true)
rec s20 sparkle repointed_tool "$( [ -n "$out" ] && [ "$rc" = 0 ] && echo 1 || echo 0)" pass 0 "$out"
rec s20 sparkle repointed_bootlog 0 text 0 "$(bootlog "$d")"
fi
wsl.exe -t "$d" >/dev/null 2>&1 || true; wsl.exe -t "$(distro restore-plain)" >/dev/null 2>&1 || true
log "done. Remove the copies when finished (your call): wsl --unregister $(distro restore-plain); wsl --unregister $d"
