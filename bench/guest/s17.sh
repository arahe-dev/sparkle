# S17 guest side, root: does everything a WSL user relies on still work? $1 = bench dir.
# Prints "<check> PASS|FAIL <detail>".
D=$1
chk() { local n=$1 out rc=0; shift; out=$("$@" 2>&1) || rc=$?
  if [ $rc = 0 ]; then echo "$n PASS $(echo "$out" | grep -v '^$' | head -1 | cut -c1-90)"; else echo "$n FAIL rc=$rc $(echo "$out" | tail -1 | cut -c1-90)"; fi; }
dev() { su - dev -c "$*"; }
chk sudo_nopasswd dev 'sudo -n true && echo ok'
chk interop_cmd_exe /mnt/c/Windows/System32/cmd.exe /c ver
chk drive_c ls -d /mnt/c/Windows
chk wslpath wslpath -w /
chk wslinfo wslinfo --networking-mode
chk dns_resolve getent hosts archive.ubuntu.com
chk wslg_display dev 'test -n "$DISPLAY" && test -e /tmp/.X11-unix/X0 && echo "DISPLAY=$DISPLAY"'
chk wslg_wayland dev 'test -n "$WAYLAND_DISPLAY" && echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"'
chk gpu_nvidia_smi /usr/lib/wsl/lib/nvidia-smi -L
chk gpu_dxg test -c /dev/dxg
cp -r $D/debs /dev/shm/debs && dpkg -i /dev/shm/debs/*.deb >/dev/null 2>&1; rm -rf /dev/shm/debs
chk gpu_opengl_d3d12 dev 'glxinfo -B | grep "OpenGL renderer" | grep -q D3D12 && glxinfo -B | grep "OpenGL renderer"'
chk ros_cli dev 'ros2 pkg list | wc -l'
chk ros_pubsub dev '(timeout 25 ros2 topic echo --once /spb17 std_msgs/msg/String > /tmp/echo.out 2>&1 &) ; sleep 4; timeout 15 ros2 topic pub -t 3 -w 1 /spb17 std_msgs/msg/String "{data: sparkle}" >/dev/null 2>&1; sleep 2; grep -q sparkle /tmp/echo.out && echo "received: sparkle"'
chk python_scipy dev 'python3 -c "import scipy.linalg as l, numpy as n; print(round(float(l.det(n.eye(3)*2)),1))"'
chk ping_unprivileged dev 'ping -c1 -W2 127.0.0.1 | tail -1'
chk file_capabilities sh -c 'python3 - <<P
import os; x=os.getxattr("/usr/bin/ping","security.capability") if os.path.exists("/usr/bin/ping") else b""; print(len(x), "bytes of security.capability on ping")
P'
chk dpkg_audit sh -c 'test -z "$(dpkg --audit)" && echo clean'
chk apt_check apt-get check -q
chk gdb dev 'gdb -batch -ex "print 6*7" | tail -1'
P=$(for f in $D/debs/*.deb; do dpkg-deb -f $f Package; done); dpkg -P $P >/dev/null 2>&1
