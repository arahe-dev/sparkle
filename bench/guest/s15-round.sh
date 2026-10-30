# S15: one "week" of ordinary use, as root (user steps as dev). $1 = bench dir.
# apt update is replayed from captured lists so every variant writes the same bytes.
D=$1
PKGS="mesa-utils python3-scipy ripgrep jq htop gdb"
rm -rf /var/lib/apt/lists/*; tar -xf $D/lists.tar -C /var/lib/apt/lists; mkdir -p /var/lib/apt/lists/partial          # apt update
mkdir -p /var/cache/apt/archives/partial; cp $D/debs/*.deb /var/cache/apt/archives/                                         # apt download
apt-get install -y --no-download $PKGS >/dev/null 2>&1                              # apt install
su - dev -c 'cd ~/ws && rm -rf build install log && colcon build >/dev/null 2>&1
  timeout 8 ros2 topic pub -r 20 /spb std_msgs/msg/String "{data: hi}" >/dev/null 2>&1
  python3 -c "import scipy.linalg, numpy, rclpy" >/dev/null 2>&1; true'           # work: build, run, python
apt-get purge -y $PKGS >/dev/null 2>&1; apt-get autoremove --purge -y >/dev/null 2>&1
X=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}
' | awk '$1=="ii"{print $2}' | sort | comm -13 $D/baseline-pkgs.txt -)
[ -n "$X" ] && apt-get purge -y $X >/dev/null 2>&1   # back to the exact clean package set; apt-get clean  # tidy user
su - dev -c 'rm -rf ~/ws/build ~/ws/install ~/ws/log'
sync
echo "df_used_bytes $(df -B1 --output=used / | tail -1)"
echo "tmpfs_used_bytes $(df -B1 --output=fstype,used /tmp /var/lib/apt/lists /var/cache/apt | awk '$1=="tmpfs"{s+=$2} END{print s+0}')"
echo "mem_used_mb $(free -m | awk '/Mem:/{print $3}')"
