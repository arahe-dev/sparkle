# Sparkle pack init: mount the read-only image under a writable overlay. Runs as root from the
# stub mount (see stub/mount), with busybox only: nothing under /usr exists yet.
B=/.sparkle/bin/busybox
exec >>/.sparkle/boot.log 2>&1
umask 022   # boot runs with umask 0: directories we create would be 777
read up _ </proc/uptime; echo "--- boot start uptime=$up pid=$$"
if $B grep -q ' /usr overlay' /proc/mounts; then echo "already mounted"; exit 0; fi
IMG=$($B cat /.sparkle/image); i=0
# Called once per drive mount: wait for the drive that holds the image.
[ "${1:-}" = fromstub ] && [ ! -f "$IMG" ] && { echo "image not on this drive yet"; exit 0; }
echo "invoked: ${1:-boot-command}"
while [ ! -f "$IMG" ] && [ $i -lt 100 ]; do $B usleep 50000; i=$((i+1)); done
[ -f "$IMG" ] || { echo "IMAGE MISSING: $IMG"; exit 1; }
# Reset: drop everything written over the image and restore the package database.
if [ -f /.sparkle/reset ]; then
  $B rm -rf /.sparkle/upper/usr /.sparkle/upper/opt /.sparkle/work/usr /.sparkle/work/opt /var/lib/dpkg
  $B mkdir -p /.sparkle/upper/usr /.sparkle/upper/opt /.sparkle/work/usr /.sparkle/work/opt
  $B cp -a /.sparkle/dpkg.seed /var/lib/dpkg; $B rm -f /.sparkle/reset
  echo "reset: upper wiped, dpkg db restored"
fi
$B mount -t squashfs -o loop,ro "$IMG" /.sparkle/lower || { echo "squashfs mount FAILED"; exit 1; }
# WSL mounts its own things under /usr before we run: GPU drivers (/usr/lib/wsl/{drivers,lib}),
# kernel modules, headers and tools (/usr/lib/modules/<kver>, /usr/src/linux-headers-<kver>,
# /usr/lib/linux-tools/<kver>). Park every mount under /usr and /opt, overlay, put them back.
: > /.sparkle/park.list; n=0
MPS=$($B awk '$2 ~ /^\/usr\// || $2 ~ /^\/opt\// {print $2}' /proc/mounts)
for mp in $MPS; do
  n=$((n+1)); $B mkdir -p /.sparkle/park/$n
  $B mount -o rbind "$mp" /.sparkle/park/$n && echo "$n $mp" >> /.sparkle/park.list && echo "parked $mp"
done
for d in usr opt; do
  $B mount -t overlay overlay -o lowerdir=/.sparkle/lower/$d,upperdir=/.sparkle/upper/$d,workdir=/.sparkle/work/$d /$d || echo "$d overlay FAILED"
done
while read -r n mp; do
  $B mkdir -p "$mp"; $B mount -o rbind /.sparkle/park/$n "$mp" && echo "restored $mp"
done < /.sparkle/park.list
# WSL links these to /init at boot, but it made them on the seed disk, now under the overlay.
for l in sbin/mount.drvfs bin/wslpath bin/wslinfo; do [ -e /usr/$l ] || $B ln -s /init /usr/$l; done
/usr/sbin/ldconfig
read up _ </proc/uptime; echo "--- boot done uptime=$up"
[ -f /.sparkle/prewarm.sh ] && $B nice -n 19 $B sh /.sparkle/prewarm.sh </dev/null >/dev/null 2>&1 &   # S19: warm ROS/C++/Python
