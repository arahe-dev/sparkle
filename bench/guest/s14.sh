# S14 guest side, root. $1 = bench dir, $2 = install|remove.
# Installs go through apt (it orders pre-dependencies; a bare `dpkg -i *.deb` does not) from the
# local .debs, with no network: --no-download and the captured package lists.
D=$1; PKGS="mesa-utils python3-scipy ripgrep jq htop gdb"
used() { df -B1 --output=used / | tail -1; }
lists() { rm -rf /var/lib/apt/lists/*; tar -xf $D/lists.tar -C /var/lib/apt/lists; mkdir -p /var/lib/apt/lists/partial; }
if [ "$2" = install ]; then
  lists; rm -rf /dev/shm/debs; cp -r $D/debs /dev/shm/debs; mkdir -p /dev/shm/debs/partial; sync
  u=$(used); s=$(date +%s%N); rc=0
  apt-get install -y --no-download -o Dir::Cache::archives=/dev/shm/debs $PKGS >/tmp/apt.out 2>&1 || rc=$?; sync
  echo "install_ms $(( ($(date +%s%N) - s) / 1000000 )) $rc"
  echo "install_df_delta_bytes $(( $(used) - u )) 0"
  rm -rf /dev/shm/debs
else
  u=$(used); s=$(date +%s%N); rc=0
  { apt-get purge -y $PKGS && apt-get autoremove --purge -y; } >/tmp/apt.out 2>&1 || rc=$?; sync
  echo "remove_ms $(( ($(date +%s%N) - s) / 1000000 )) $rc"
  echo "remove_df_delta_bytes $(( $(used) - u )) 0"
X=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}
' | awk '$1=="ii"{print $2}' | sort | comm -13 $D/baseline-pkgs.txt -)
[ -n "$X" ] && apt-get purge -y $X >/dev/null 2>&1   # back to the exact clean package set
  echo "left_after_autoremove $(echo "$X" | grep -c .) 0"
fi
echo "dpkg_installed $(dpkg -l | grep -c '^ii') 0"
echo "dpkg_audit_lines $(dpkg --audit | grep -c .) 0"
