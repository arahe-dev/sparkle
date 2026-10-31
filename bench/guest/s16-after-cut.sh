# S16 guest side, root, first boot after the VM was killed during `apt-get install`.
# $1 = bench dir, $2 = repo dir. Prints `metric value unit` lines.
# Order matters: record the damage first, then repair, then prove the same install works again,
# then go back to the exact clean package set.
D=$1 R=$2
# Packages outside the baseline, with their dpkg status (ii = installed, anything else = half-done).
extra() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}
' | awk 'NR==FNR{b[$1];next} !($2 in b) && $1!~/^un/' $D/baseline-pkgs.txt -; }
echo "extra_installed $(extra | awk '$1=="ii"' | grep -c .) count"
echo "extra_half_done $(extra | awk '$1!="ii"' | grep -c .) count"
echo "audit_lines_before $(dpkg --audit 2>&1 | grep -c .) count"
rc=0; dpkg --configure -a >/tmp/s16-cfg.out 2>&1 || rc=$?; echo "configure_rc $rc rc"
rc=0; apt-get install -f -y --no-download >/tmp/s16-fix.out 2>&1 || rc=$?; echo "fix_rc $rc rc"
echo "audit_lines_after $(dpkg --audit 2>&1 | grep -c .) count"
rc=0; apt-get check >/dev/null 2>&1 || rc=$?; echo "apt_check_rc $rc rc"
# The interrupted install, run again on the repaired system (same script and debs as S14).
bash $R/bench/guest/s14.sh $D install | awk '$1=="install_ms"{print "reinstall_rc", $3, "rc"}'
bash $R/bench/guest/s14.sh $D remove >/dev/null
# Anything still outside the baseline (half-installed leftovers included) goes, by force.
X=$(extra | awk '{print $2}'); [ -n "$X" ] && dpkg --purge --force-all $X >/dev/null 2>&1
echo "dpkg_after $(dpkg -l | grep -c '^ii') count"
echo "audit_lines_final $(dpkg --audit 2>&1 | grep -c .) count"
