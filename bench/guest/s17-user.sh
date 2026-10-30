# S17 checks that need a real user session (as dev, started by wsl.exe, not su): WSL sets
# DISPLAY and WAYLAND_DISPLAY for the session, and su would wipe them.
set -o pipefail
chk() { local n=$1 out rc=0; shift; out=$("$@" 2>&1 </dev/null) || rc=$?
  if [ $rc = 0 ]; then echo "$n PASS $(echo "$out" | grep -v '^$' | head -1 | cut -c1-90)"; else echo "$n FAIL rc=$rc $(echo "$out" | tail -1 | cut -c1-90)"; fi; }
chk wslg_x11 sh -c 'test -n "$DISPLAY" && test -S /tmp/.X11-unix/X0 && echo "DISPLAY=$DISPLAY, socket ok"'
chk wslg_wayland sh -c 'test -n "$WAYLAND_DISPLAY" && test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY, socket ok"'
chk gpu_opengl_d3d12 sh -c 'glxinfo -B | grep "OpenGL renderer" | grep D3D12'
chk tmp_is sh -c 'findmnt -n -o FSTYPE /tmp; true'
