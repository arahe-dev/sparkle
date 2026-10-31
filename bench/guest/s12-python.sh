# S12 guest side for a plain-Python image (python:3.12-bookworm): same shape as s12.sh, with
# Python/C tools in place of the ROS ones. $1 = cold|warm. Prints "<metric> <ms> <rc>".
mode=$1
drop() { if [ "$mode" = cold ]; then sync; echo 3 > /proc/sys/vm/drop_caches; fi; }
t() { local m=$1 s rc=0; shift; drop; s=$(date +%s%N); "$@" >/dev/null 2>&1 || rc=$?; echo "$m $(( ($(date +%s%N) - s) / 1000000 )) $rc"; }
asdev() { su - dev -c "$*"; }
cat > /dev/shm/h.c <<'C'
#include <stdio.h>
#include <math.h>
int main(void) { printf("%f\n", sqrt(2.0)); return 0; }
C
t full_read_usr_opt sh -c 'tar --one-file-system -cf - /usr /opt | wc -c'
t metadata_walk sh -c 'find /usr /opt -xdev | wc -l'
t python_import_stdlib asdev "python3 -c 'import asyncio, json, email.parser, http.client, xml.etree.ElementTree, sqlite3, decimal, unittest, multiprocessing, ssl, ctypes'"
t pip_version asdev "python3 -m pip --version"
t gcc_compile_c gcc -O2 -o /dev/shm/h /dev/shm/h.c -lm
