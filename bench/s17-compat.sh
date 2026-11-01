#!/usr/bin/env bash
# S17: compatibility matrix. Every check runs on every variant.
. "$(dirname "$0")/lib/host.sh"
: > "$RAW/s17.jsonl"
for v in "${VARIANTS[@]}"; do
  u=$(wsl.exe -d "$(distro $v)" --cd / --exec /usr/bin/whoami 2>/dev/null | tr -d '\r')
  rec s17 "$v" default_user "$( [ "$u" = dev ] && echo 1 || echo 0)" pass 0 "$u"
  wx "$(distro $v)" root "$BENCH_WSL" < "$REPO/bench/guest/s17$GUEST.sh" | while read -r c res detail; do
    rec s17 "$v" "$c" "$( [ "$res" = PASS ] && echo 1 || echo 0)" pass 0 "$(echo "$detail" | tr -d '"\')"; done
  wx "$(distro $v)" dev < "$REPO/bench/guest/s17-user.sh" | while read -r c res detail; do
    rec s17 "$v" "$c" "$( [ "$res" = PASS ] && echo 1 || echo 0)" pass 0 "$(echo "$detail" | tr -d '"\')"; done
  wx "$(distro $v)" root "$BENCH_WSL" <<'SH' >/dev/null
D=$1
apt-get purge -y mesa-utils python3-scipy ripgrep jq htop gdb >/dev/null 2>&1; apt-get autoremove --purge -y >/dev/null 2>&1
X=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}
' | awk '$1=="ii"{print $2}' | sort | comm -13 $D/baseline-pkgs.txt -)
[ -n "$X" ] && apt-get purge -y $X >/dev/null 2>&1; true
SH
  log "$v done"
done

