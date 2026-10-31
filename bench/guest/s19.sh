# S19 guest side (root, bench distro). $1 = cold|warm|prew|race, $2 = variant, $3 = prewarm.sh.
# Prints "<metric> <value> <rc>". cold: guest page cache dropped before each metric.
# prew: dropped, then prewarm.sh run to completion first. race: dropped, prewarm.sh started in
# the background and the metric timed at once (a command typed right after boot).
mode=$1 v=$2 PW=$3 R=/mnt/s19/$2
cached() { awk '/^Cached:/{print $2}' /proc/meminfo; }
prep() {
  [ "$mode" = warm ] && return
  sync; echo 3 > /proc/sys/vm/drop_caches
  case $mode in
  prew) local c s; c=$(cached); s=$(date +%s%N); nice -n 19 sh "$PW" "$R"
    echo "prewarm_${1}_ms $(( ($(date +%s%N) - s) / 1000000 )) 0"
    echo "prewarm_${1}_cache_mb $(( ($(cached) - c) / 1024 )) 0" ;;
  race) nice -n 19 sh "$PW" "$R" & ;;
  esac; }
t() { local m=$1 s rc=0; shift; prep "$m"; s=$(date +%s%N); chroot "$R" "$@" >/dev/null 2>&1 || rc=$?
  echo "$m $(( ($(date +%s%N) - s) / 1000000 )) $rc"; wait; }
printf '#include <rclcpp/rclcpp.hpp>\n#include <std_msgs/msg/string.hpp>\nint main(){return 0;}\n' > $R/dev/shm/h.cpp
t metadata_walk sh -c 'find /usr /opt -xdev | wc -l'
t python_import_rclpy su - dev -c "python3 -c 'import rclpy'"
t ros2_pkg_list su - dev -c "ros2 pkg list"
t gxx_rclcpp_headers sh -c 'g++ -std=c++17 -fsyntax-only $(for d in /opt/ros/jazzy/include/*; do printf -- "-I%s " $d; done) /dev/shm/h.cpp'
