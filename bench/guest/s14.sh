# S14 guest side, root. $1 = bench dir, $2 = install|remove.
D=$1
used() { df -B1 --output=used / | tail -1; }
if [ "$2" = install ]; then
  rm -rf /dev/shm/debs; cp -r $D/debs /dev/shm/debs; sync
  u=$(used); s=$(date +%s%N); rc=0
  dpkg -i /dev/shm/debs/*.deb >/tmp/dpkg.out 2>&1 || rc=$?; sync
  echo "install_ms $(( ($(date +%s%N) - s) / 1000000 )) $rc"
  echo "install_df_delta_bytes $(( $(used) - u )) 0"
  rm -rf /dev/shm/debs
else
  P=$(for f in $D/debs/*.deb; do dpkg-deb -f $f Package; done)
  u=$(used); s=$(date +%s%N); rc=0
  dpkg -P $P >/tmp/dpkg.out 2>&1 || rc=$?; sync
  echo "remove_ms $(( ($(date +%s%N) - s) / 1000000 )) $rc"
  echo "remove_df_delta_bytes $(( $(used) - u )) 0"
fi
echo "dpkg_installed $(dpkg -l | grep -c '^ii') 0"
