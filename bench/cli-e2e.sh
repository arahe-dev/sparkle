#!/usr/bin/env bash
# CLI end to end: the release sparkle.exe against ros:jazzy-ros-base, timed from the host.
#   cli-e2e.sh <sparkle.exe>      (SPARKLE_HOME defaults to %USERPROFILE%\sparkle-cli-e2e)
# add once with the download, then N cached adds (eject between them), then N cold enters
# and N resets. Only `wsl -t` of the pack; never --shutdown.
. "$(dirname "$0")/lib/host.sh"
EXE=${1:?usage: cli-e2e.sh <sparkle.exe>}; N=${N:-3}
export SPARKLE_HOME=${SPARKLE_HOME:-$USERPROFILE\\sparkle-cli-e2e}
: > "$RAW/cli.jsonl"
d=sparkle-e2e
# add prints: added <d>: download <x>, flatten <a> s, build <b> s, import <c> s, total <t> s
add() { local out; out=$("$EXE" add e2e --image ros:jazzy-ros-base 2>&1 | tr -d '\r' | tee >(cat >&2) | grep '^added ') || return 1
  echo "$out" | sed -E 's/download cached/download 0 s/; s/.*download ([0-9.]+) s, flatten ([0-9.]+) s, build ([0-9.]+) s, import ([0-9.]+) s, total ([0-9.]+) s/\1 \2 \3 \4 \5/'; }
ms() { awk -v s="$1" 'BEGIN{printf "%d", s*1000}'; }
"$EXE" eject e2e >/dev/null 2>&1 || true
for r in $(seq 0 "$N"); do
  [ "$r" -gt 0 ] && "$EXE" eject e2e >/dev/null
  out=$(add) || { rec cli sparkle add_failed 1 bool "$r"; exit 1; }
  read -r dl fl bu im tot <<<"$out"
  [ "$r" = 0 ] && rec cli sparkle download_ms "$(ms "$dl")" ms 0
  for m in flatten:$fl build:$bu import:$im total:$tot; do
    rec cli sparkle "add_${m%%:*}_ms$([ "$r" = 0 ] && echo _first)" "$(ms "${m#*:}")" ms "$r"; done
done
rec cli sparkle pack_bytes "$(( $(stat -c %s "$(cygpath -u "$SPARKLE_HOME")/packs/e2e/image.sqfs") + $(stat -c %s "$(cygpath -u "$SPARKLE_HOME")/packs/e2e/ext4.vhdx") ))" B
for r in $(seq 1 "$N"); do
  wsl.exe -t "$d" >/dev/null 2>&1 || true
  t0=$(now_ms); n=$("$EXE" enter e2e -- 'ros2 pkg list | wc -l' 2>/dev/null | tr -d '\r' | tail -1)
  rec cli sparkle enter_cold_ms "$(since_ms $t0)" ms "$r" "pkgs=$n"
  t0=$(now_ms); "$EXE" enter e2e -- true >/dev/null 2>&1; rec cli sparkle enter_warm_ms "$(since_ms $t0)" ms "$r"
done
for r in $(seq 1 "$N"); do
  wsl.exe -d "$d" -u root --cd / --exec /usr/bin/touch /usr/local/bin/e2e-marker
  t0=$(now_ms); "$EXE" reset e2e >/dev/null; rec cli sparkle reset_ms "$(since_ms $t0)" ms "$r"
  t0=$(now_ms); gone=$("$EXE" enter e2e -- 'test -e /usr/local/bin/e2e-marker && echo 0 || echo 1' 2>/dev/null | tr -d '\r' | tail -1)
  rec cli sparkle reset_then_enter_ms "$(since_ms $t0)" ms "$r"; rec cli sparkle reset_dropped_marker "${gone:-0}" bool "$r"
done
mv "$(cygpath -u "$SPARKLE_HOME")/packs/e2e/image.sqfs"{,.away}
rc=0; msg=$("$EXE" enter e2e -- true 2>&1 | tr -d '\r' | head -1) || rc=$?
mv "$(cygpath -u "$SPARKLE_HOME")/packs/e2e/image.sqfs"{.away,}
rec cli sparkle missing_image_rc "$rc" rc 0 "$(echo "$msg" | tr '\\' '/' | sed -E 's#[A-Za-z]:/Users/[^/]+#<home>#g' | tr -d '"')"   # no user paths in public data
"$EXE" eject e2e >/dev/null; rec cli sparkle ejected 1 bool
log done
