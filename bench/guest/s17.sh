# S17 guest side, root: does everything a WSL user relies on still work? $1 = bench dir.
# Prints "<check> PASS|FAIL <detail>".
D=$1
set -o pipefail   # a check fails if any part of its pipeline fails
# stdin is closed for every check: the script itself arrives on stdin, and Windows tools such as
# cmd.exe would read (and swallow) the rest of it.
chk() { local n=$1 out rc=0; shift; out=$("$@" 2>&1 </dev/null) || rc=$?
  if [ $rc = 0 ]; then echo "$n PASS $(echo "$out" | grep -v '^$' | head -1 | cut -c1-90)"; else echo "$n FAIL rc=$rc $(echo "$out" | tail -1 | cut -c1-90)"; fi; }
dev() { su - dev -c "$*"; }
chk sudo_nopasswd dev 'sudo -n true && echo ok'
chk interop_cmd_exe sh -c 'cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c ver'
chk drive_c ls -d /mnt/c/Windows
chk wslpath wslpath -w /
chk wslinfo wslinfo --networking-mode
chk dns_resolve getent hosts archive.ubuntu.com
chk gpu_nvidia_smi sh -c "/usr/lib/wsl/lib/nvidia-smi -L | sed 's/ (UUID:.*//'"   # hardware UUID dropped: results are public
chk gpu_dxg test -c /dev/dxg
PKGS="mesa-utils python3-scipy ripgrep jq htop gdb"
rm -rf /var/lib/apt/lists/*; tar -xf $D/lists.tar -C /var/lib/apt/lists; mkdir -p /var/lib/apt/lists/partial
cp -r $D/debs /dev/shm/debs; mkdir -p /dev/shm/debs/partial
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download -o Dir::Cache::archives=/dev/shm/debs $PKGS >/dev/null 2>&1 </dev/null; rm -rf /dev/shm/debs
chk ros_cli dev 'ros2 pkg list | wc -l'
chk ros_pubsub dev '(timeout 25 ros2 topic echo --once /spb17 std_msgs/msg/String > /tmp/echo.out 2>&1 &) ; sleep 4; timeout 15 ros2 topic pub -t 3 -w 1 /spb17 std_msgs/msg/String "{data: sparkle}" >/dev/null 2>&1; sleep 2; grep -q sparkle /tmp/echo.out && echo "received: sparkle"'
chk python_scipy dev 'python3 -c "import scipy.linalg as l, numpy as n; print(round(float(l.det(n.eye(3)*2)),1))"'
chk dpkg_audit sh -c 'test -z "$(dpkg --audit)" && echo clean'
chk apt_check apt-get check -q
chk gdb dev 'gdb -batch -ex "print 6*7" | tail -1'
