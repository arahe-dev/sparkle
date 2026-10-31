# S19 setup in the bench distro (root). $1 = WSL path of the dir holding v-*.img.
# Every variant gets its own root: a non-recursive bind of the seed / (so /etc etc. are shared)
# with that variant's /usr and /opt mounted on top. Commands then run in `chroot /mnt/s19/<v>`.
#   plain        the tree copied onto this distro's ext4 (the reference)
#   sq128..eroraw  image on NTFS under overlay (tmpfs upper), as Sparkle mounts it
#   sqraw_direct  uncompressed squashfs without overlay (overlay cost)
set -eu
D=$1 S=/var/s19
mkdir -p $S
# This seed imported with / at 0700, which stops `su - dev` (see S19 notes); the pack wants 0755.
chmod 755 /
[ -d $S/plain/usr ] || { mkdir -p $S/plain; cp -a /mnt/wsl/s19-tree/root/. $S/plain/; }
for v in plain sq128 sq1m sqraw erolz4 eroraw sqraw_direct; do
  R=/mnt/s19/$v
  mountpoint -q $R && continue
  mkdir -p $R; mount --bind / $R
  if [ $v = plain ]; then mount --bind $S/plain/usr $R/usr; mount --bind $S/plain/opt $R/opt
  else
    img=${v%_direct} L=$S/lower-$v; mkdir -p $L
    case $img in sq*) mount -t squashfs -o loop,ro $D/v-$img.img $L ;; ero*) mount -t erofs -o ro $D/v-$img.img $L ;; esac
    if [ $v = sqraw_direct ]; then mount --bind $L/usr $R/usr; mount --bind $L/opt $R/opt
    else U=$S/up-$v; mkdir -p $U; mount -t tmpfs tmpfs $U
      for d in usr opt; do mkdir -p $U/u$d $U/w$d
        mount -t overlay overlay -o lowerdir=$L/$d,upperdir=$U/u$d,workdir=$U/w$d $R/$d; done
    fi
  fi
  mount -t proc proc $R/proc; mount --rbind /dev $R/dev; mount -t sysfs sys $R/sys
  echo "$v ok: $(chroot $R python3 -c 'import sys; print(sys.version.split()[0])')"
done
grep -E ' /mnt/s19/| /var/s19/' /proc/mounts | awk '{print $3, $1, $2}' | sort -u | head -40
losetup -a 2>/dev/null | sed 's|/mnt/c/Users/[^/]*|<home>|'
