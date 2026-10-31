# S18 guest side, root: package state and S17-style basics after a reset. $1 = bench dir.
# Prints "metric value".
D=$1
echo "dpkg_installed $(dpkg -l | grep -c '^ii')"
echo "dpkg_audit_lines $(dpkg --audit | grep -c .)"
echo "extra_vs_baseline $(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' | awk '$1=="ii"{print $2}' | sort | comm -13 $D/baseline-pkgs.txt - | grep -c .)"
echo "upper_used_bytes $(df -B1 --output=used /.sparkle/u 2>/dev/null | tail -1 | tr -d ' ' | grep . || echo -1)"
ok() { "$@" >/dev/null 2>&1 </dev/null && echo 1 || echo 0; }
echo "ok_drive_c $(ok ls -d /mnt/c/Windows)"
echo "ok_wslpath $(ok wslpath -w /)"
echo "ok_gpu_dxg $(ok test -c /dev/dxg)"
echo "ros2_pkgs $(su - dev -c 'ros2 pkg list 2>/dev/null | wc -l' </dev/null)"
echo "ok_etc_overlay $(findmnt -rn -o FSTYPE /etc | grep -c overlay)"
echo "ok_varlib_overlay $(findmnt -rn -o FSTYPE /var/lib | grep -c overlay)"
