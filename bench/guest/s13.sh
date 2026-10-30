# S13 guest side, as dev. $1 = setup|build. A small but real ROS 2 workspace:
# 4 C++ packages (rclcpp node each) + 1 Python package.
set -e
W=~/ws
if [ "$1" = setup ]; then
  rm -rf $W; mkdir -p $W/src; cd $W/src
  for i in 1 2 3 4; do ros2 pkg create --build-type ament_cmake --dependencies rclcpp std_msgs --node-name node$i cpp_pkg$i >/dev/null; done
  ros2 pkg create --build-type ament_python --dependencies rclpy std_msgs --node-name pynode py_pkg >/dev/null
  exit 0
fi
cd $W; rm -rf build install log
s=$(date +%s%N); colcon build --event-handlers console_direct- >/tmp/colcon.out 2>&1 || { tail -20 /tmp/colcon.out; exit 1; }
echo "colcon_build_ms $(( ($(date +%s%N) - s) / 1000000 ))"
echo "build_dir_mb $(du -sm build install log | awk '{s+=$1} END {print s}')"
