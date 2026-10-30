# S15: one "week" of ordinary use, as root (user steps as dev). $1 = bench dir.
# apt update is replayed from captured lists so every variant writes the same bytes.
D=$1
P=$(for f in $D/debs/*.deb; do dpkg-deb -f $f Package; done)
rm -rf /var/lib/apt/lists/*; tar -xf $D/lists.tar -C /var/lib/apt/lists          # apt update
cp $D/debs/*.deb /var/cache/apt/archives/                                         # apt download
dpkg -i /var/cache/apt/archives/*.deb >/dev/null 2>&1                             # apt install
su - dev -c 'cd ~/ws && rm -rf build install log && colcon build >/dev/null 2>&1
  timeout 8 ros2 topic pub -r 20 /spb std_msgs/msg/String "{data: hi}" >/dev/null 2>&1
  python3 -c "import scipy.linalg, numpy, rclpy" >/dev/null 2>&1; true'           # work: build, run, python
dpkg -P $P >/dev/null 2>&1; apt-get clean                                         # tidy user: remove + clean
su - dev -c 'rm -rf ~/ws/build ~/ws/install ~/ws/log'
sync
echo "df_used_bytes $(df -B1 --output=used / | tail -1)"
echo "tmpfs_used_bytes $(df -B1 --output=fstype,used /tmp /var/lib/apt/lists /var/cache/apt | awk '$1=="tmpfs"{s+=$2} END{print s+0}')"
echo "mem_used_mb $(free -m | awk '/Mem:/{print $3}')"
