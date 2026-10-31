# S17 guest side for a plain-Python image, root: the WSL basics from s17.sh plus Python/C checks
# in place of the ROS ones. No sudo check: python:* images ship without sudo. $1 = bench dir.
# Prints "<check> PASS|FAIL <detail>".
set -o pipefail
chk() { local n=$1 out rc=0; shift; out=$("$@" 2>&1 </dev/null) || rc=$?
  if [ $rc = 0 ]; then echo "$n PASS $(echo "$out" | grep -v '^$' | head -1 | cut -c1-90)"; else echo "$n FAIL rc=$rc $(echo "$out" | tail -1 | cut -c1-90)"; fi; }
dev() { su - dev -c "$*"; }
chk interop_cmd_exe sh -c 'cd /mnt/c && /mnt/c/Windows/System32/cmd.exe /c ver'
chk drive_c ls -d /mnt/c/Windows
chk wslpath wslpath -w /
chk wslinfo wslinfo --networking-mode
chk dns_resolve getent hosts deb.debian.org
chk gpu_nvidia_smi sh -c "/usr/lib/wsl/lib/nvidia-smi -L | sed 's/ (UUID:.*//'"   # hardware UUID dropped: results are public
chk gpu_dxg test -c /dev/dxg
chk python_version dev 'python3 --version'
chk pip_version dev 'python3 -m pip --version | cut -d" " -f1-2'
chk python_stdlib dev 'python3 -c "import sqlite3, ssl, ctypes, json; print(sqlite3.sqlite_version, ssl.OPENSSL_VERSION)"'
chk pip_venv dev 'python3 -m venv /tmp/v && /tmp/v/bin/python -c "import sys; print(sys.prefix)"'
chk gcc_hello dev 'printf "#include <stdio.h>\nint main(void){puts(\"hi\");return 0;}\n" > /tmp/h.c && gcc -o /tmp/h /tmp/h.c && /tmp/h'
# Online install (the image's apt lists are empty, and no offline .deb set exists for Debian here).
chk apt_install_jq sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq >/dev/null && jq --version'
chk dpkg_audit sh -c 'test -z "$(dpkg --audit)" && echo clean'
chk apt_check apt-get check -q
