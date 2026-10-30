#!/usr/bin/env bash
# S17: compatibility matrix. Every check runs on every variant.
. "$(dirname "$0")/lib/host.sh"
: > "$RAW/s17.jsonl"
for v in "${VARIANTS[@]}"; do
  u=$(wsl.exe -d "$(distro $v)" --cd / --exec /usr/bin/whoami 2>/dev/null | tr -d '\r')
  rec s17 "$v" default_user "$( [ "$u" = dev ] && echo 1 || echo 0)" pass 0 "$u"
  wx "$(distro $v)" root "$BENCH_WSL" < "$REPO/bench/guest/s17.sh" | while read -r c res detail; do
    rec s17 "$v" "$c" "$( [ "$res" = PASS ] && echo 1 || echo 0)" pass 0 "$(echo "$detail" | tr -d '"\')"; done
  log "$v done"
done

