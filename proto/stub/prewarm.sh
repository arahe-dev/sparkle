#!/.sparkle/bin/busybox sh
# Sparkle prewarm: after boot, read the hot parts of the pack image (ROS, C++ headers, Python)
# into the guest page cache at low priority, so the first python/ROS/C++ command doesn't pay
# for cold reads from the image file on NTFS. init.sh starts it in the background.
# $1 = root prefix (benchmarks run it against a mounted variant; empty at boot).
B=/.sparkle/bin/busybox
R=${1:-}
for d in "$R"/opt/ros "$R"/usr/include "$R"/usr/lib/python3.* "$R"/usr/lib/python3/dist-packages; do
  [ -d "$d" ] && $B find "$d" -type f -print0
done | $B xargs -0 -r $B cat >/dev/null 2>&1
exit 0
