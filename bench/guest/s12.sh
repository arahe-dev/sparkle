# S12 guest side. $1 = cold|warm. Prints "<metric> <ms> <rc>". Runs as root; user tools as dev.
mode=$1
drop() { if [ "$mode" = cold ]; then sync; echo 3 > /proc/sys/vm/drop_caches; fi; }
t() { local m=$1 s rc=0; shift; drop; s=$(date +%s%N); "$@" >/dev/null 2>&1 || rc=$?; echo "$m $(( ($(date +%s%N) - s) / 1000000 )) $rc"; }
asdev() { su - dev -c "$*"; }
INC=$(for d in /opt/ros/jazzy/include/*; do printf -- '-I%s ' "$d"; done)
printf '#include <rclcpp/rclcpp.hpp>\n#include <std_msgs/msg/string.hpp>\nint main(){return 0;}\n' > /dev/shm/h.cpp
# GNU tar skips reading file data when writing to /dev/null, so pipe through wc.
t full_read_usr_opt sh -c 'tar --one-file-system -cf - /usr /opt | wc -c'
t metadata_walk sh -c 'find /usr /opt -xdev | wc -l'
t python_import_rclpy asdev "python3 -c 'import rclpy'"
t ros2_pkg_list asdev "ros2 pkg list"
t gxx_rclcpp_headers g++ -std=c++17 -fsyntax-only $INC /dev/shm/h.cpp
