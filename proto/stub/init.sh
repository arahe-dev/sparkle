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
# With an upper file (/.sparkle/upper-img), reset is deleting that file: Windows gets the space back.
UF=$($B cat /.sparkle/upper-img 2>/dev/null || true)
if [ -f /.sparkle/reset ]; then
  if [ -n "$UF" ]; then $B rm -f "$UF"; else
  $B rm -rf /.sparkle/upper/usr /.sparkle/upper/opt /.sparkle/work/usr /.sparkle/work/opt /var/lib/dpkg
  $B mkdir -p /.sparkle/upper/usr /.sparkle/upper/opt /.sparkle/work/usr /.sparkle/work/opt
  $B cp -a /.sparkle/dpkg.seed /var/lib/dpkg; fi
  $B rm -f /.sparkle/reset; echo "reset: upper wiped, dpkg db restored"
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
[ -n "$UF" ] && [ ! -f "$UF" ] && { echo "UPPER FILE MISSING: $UF, using the seed disk"; UF=; }
if [ -n "$UF" ]; then
  # Upper file: a sparse ext4 image next to the pack image. The host creates it sparse and empty
  # (a size extended from inside WSL is allocated in full on NTFS); the first boot formats it with
  # the image's own mke2fs. It holds the writes over /usr, /opt, /etc and /var/lib.
  L=/.sparkle/lower; LD=$L/usr/lib/x86_64-linux-gnu
  if [ "$($B dd if="$UF" bs=1 skip=1080 count=2 2>/dev/null | $B od -An -tx1 | $B tr -d ' ')" != 53ef ]; then
    $LD/ld-linux-x86-64.so.2 --library-path $LD $L/usr/sbin/mke2fs -q -t ext4 -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1 "$UF" &&
    echo "upper file formatted: $UF" || echo "upper file format FAILED"
  fi
  $B mkdir -p /.sparkle/u
  $B mount -t ext4 -o loop,noatime "$UF" /.sparkle/u || { echo "UPPER FILE MOUNT FAILED, using the seed disk"; UF=; }
fi
if [ -n "$UF" ]; then
  for d in usr opt etc varlib; do $B mkdir -p /.sparkle/u/up/$d /.sparkle/u/wk/$d; done
  for d in usr opt; do
    $B mount -t overlay overlay -o lowerdir=$L/$d,upperdir=/.sparkle/u/up/$d,workdir=/.sparkle/u/wk/$d /$d || echo "$d overlay FAILED"
  done
  # /etc and /var/lib: the seed's own copy is the lower layer, so reset also drops package
  # configs and the dpkg/apt state. /home, /root and /var/log stay on the seed disk.
  $B mount -t overlay overlay -o lowerdir=/etc,upperdir=/.sparkle/u/up/etc,workdir=/.sparkle/u/wk/etc /etc || echo "etc overlay FAILED"
  $B mount -t overlay overlay -o lowerdir=/var/lib,upperdir=/.sparkle/u/up/varlib,workdir=/.sparkle/u/wk/varlib /var/lib || echo "var/lib overlay FAILED"
else
for d in usr opt; do
  $B mount -t overlay overlay -o lowerdir=/.sparkle/lower/$d,upperdir=/.sparkle/upper/$d,workdir=/.sparkle/work/$d /$d || echo "$d overlay FAILED"
done
fi
while read -r n mp; do
  $B mkdir -p "$mp"; $B mount -o rbind /.sparkle/park/$n "$mp" && echo "restored $mp"
done < /.sparkle/park.list
# WSL links these to /init at boot, but it made them on the seed disk, now under the overlay.
for l in sbin/mount.drvfs bin/wslpath bin/wslinfo; do [ -e /usr/$l ] || $B ln -s /init /usr/$l; done
/usr/sbin/ldconfig
read up _ </proc/uptime; echo "--- boot done uptime=$up"
[ -f /.sparkle/prewarm.on ] && $B nice -n 19 $B sh /.sparkle/prewarm.sh </dev/null >/dev/null 2>&1 &   # S19: opt-in, see results
