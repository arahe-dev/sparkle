#!/usr/bin/env bash
# S20: backup and restore with `wsl --export` / `wsl --import` (S16 only timed the export).
#   1. export plain and sparkle to tar files, import each as a new distro <prefix>-restore-<v>
#   2. boot each restored distro: does the probe file exist (image mounted) and do tools run?
#   3. sparkle only: point the restored pack's /.sparkle/image at a folder with no image (what a
#      restore onto another PC, or after moving the image, looks like), boot, record what happens;
#      then point it at a copy of the image in a new folder and boot again.
# Creates <prefix>-restore-plain/-sparkle; never unregisters anything (print the command instead).
. "$(dirname "$0")/lib/host.sh"
: > "$RAW/s20.jsonl"
CHECK=${SPARKLE_RESTORE_CHECK:-python3 --version}   # a tool from the image, run as dev
X="$BENCH/export"; mkdir -p "$X"
exists() { wsl.exe -l -q 2>/dev/null | tr -d '\0\r' | grep -qx "$1"; }
probe() { local rc=0; timeout 90 wsl.exe -d "$1" -u dev --cd / --exec /usr/bin/test -e "$PROBE" 2>/dev/null </dev/null || rc=$?; echo $rc; }
bootlog() { timeout 60 wsl.exe -d "$1" -u root --cd / --exec /.sparkle/bin/busybox tail -2 /.sparkle/boot.log 2>&1 </dev/null \
  | tr -d '\r"\' | tr '\n' ' ' | sed "s#$BENCH_WSL#<bench>#g" || true; }   # no user paths in public data
setimg() { # <distro> <wsl path>: rewrite /.sparkle/image with busybox (works with /usr unmounted)
  echo "$2" | timeout 60 wsl.exe -d "$1" -u root --cd / --exec /.sparkle/bin/busybox sh -c 'cat > /.sparkle/image'; }

for v in plain sparkle; do
  src=$(distro $v) dst=$(distro restore-$v)
  wsl.exe -t "$src" >/dev/null 2>&1 || true
  t0=$(now_ms); wsl.exe --export "$src" "$(cygpath -w "$X/$v.tar")"
  rec s20 "$v" export_ms "$(since_ms $t0)" ms; rec s20 "$v" export_tar_bytes "$(stat -c %s "$X/$v.tar")" B
  if exists "$dst"; then log "$dst exists; to redo: wsl --unregister $dst"; else
    mkdir -p "$BENCH/distros/restore-$v"; t0=$(now_ms)
    wsl.exe --import "$dst" "$(cygpath -w "$BENCH/distros/restore-$v")" "$(cygpath -w "$X/$v.tar")" --version 2
    rec s20 "$v" import_ms "$(since_ms $t0)" ms; fi
  t0=$(now_ms); rc=$(probe "$dst"); rec s20 "$v" restored_boot_probe_rc "$rc" rc 0 "first boot of the restored distro"
  rec s20 "$v" restored_boot_ms "$(since_ms $t0)" ms
  out=$(timeout 60 wsl.exe -d "$dst" -u dev --cd / -- sh -c "$CHECK" 2>&1 </dev/null | tr -d '\r"\' | head -1 || true)
  rec s20 "$v" restored_tool "$( [ -n "$out" ] && [ "$rc" = 0 ] && echo 1 || echo 0)" pass 0 "$out"
  u=$(wsl.exe -d "$dst" --cd / --exec /usr/bin/whoami 2>/dev/null </dev/null | tr -d '\r' || true)
  rec s20 "$v" restored_default_user "$( [ "$u" = dev ] && echo 1 || echo 0)" pass 0 "$u"
done

d=$(distro restore-sparkle)
rec s20 sparkle restored_image_path 0 text 0 "$(wsl.exe -d "$d" -u root --exec /.sparkle/bin/busybox cat /.sparkle/image 2>/dev/null | tr -d '\r' | sed "s#$BENCH_WSL#<bench>#g")"
log "image not where the pack expects it"
setimg "$d" "$BENCH_WSL/gone/image.sqfs"; wsl.exe -t "$d" >/dev/null 2>&1 || true
t0=$(now_ms); rc=$(probe "$d"); rec s20 sparkle moved_image_probe_rc "$rc" rc 0 "image path points at a folder with no image"
rec s20 sparkle moved_image_boot_ms "$(since_ms $t0)" ms
rec s20 sparkle moved_image_bootlog 0 text 0 "$(bootlog "$d")"
log "fix: copy the image to a new folder and write that path into /.sparkle/image"
mkdir -p "$BENCH/moved"; cp "$BENCH/image.sqfs" "$BENCH/moved/image.sqfs"
setimg "$d" "$BENCH_WSL/moved/image.sqfs"; wsl.exe -t "$d" >/dev/null 2>&1 || true
t0=$(now_ms); rc=$(probe "$d"); rec s20 sparkle repointed_probe_rc "$rc" rc 0 "after writing the new path into /.sparkle/image"
rec s20 sparkle repointed_boot_ms "$(since_ms $t0)" ms
out=$(timeout 60 wsl.exe -d "$d" -u dev --cd / -- sh -c "$CHECK" 2>&1 </dev/null | tr -d '\r"\' | head -1 || true)
rec s20 sparkle repointed_tool "$( [ -n "$out" ] && [ "$rc" = 0 ] && echo 1 || echo 0)" pass 0 "$out"
rec s20 sparkle repointed_bootlog 0 text 0 "$(bootlog "$d")"
wsl.exe -t "$d" >/dev/null 2>&1 || true; wsl.exe -t "$(distro restore-plain)" >/dev/null 2>&1 || true
log "done. Remove the copies when finished (your call): wsl --unregister $(distro restore-plain); wsl --unregister $d"
