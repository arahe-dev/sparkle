# Build the three benchmark variants from one extracted image tree. Runs as root in a helper
# distro that has mksquashfs >= 4.6. The tree must already be extracted at $T (see
# bench/s10-fixtures.sh), so every variant is cut from the same bytes.
#   build-fixtures.sh <stage> <tree> <out dir (WSL path on an automounted drive)> <busybox>
#   stage: setup | tuned | sparkle
set -eu
STAGE=$1 T=$2 OUT=$3 BB=${4:-}
P=$(dirname "$(readlink -f "$0")")
case $STAGE in
setup)
  cp "$P/common-setup.sh" "$T/tmp/cs.sh"; chroot "$T" /bin/sh /tmp/cs.sh; rm "$T/tmp/cs.sh"
  # The clean package set every benchmark step returns to.
  mkdir -p "$OUT"
  chroot "$T" dpkg-query -W -f='${db:Status-Abbrev} ${Package}
' | awk '$1=="ii"{print $2}' | sort > "$OUT/baseline-pkgs.txt" ;;
tuned)
  # plain + the volatile paths: what a careful WSL user can do with fstab alone.
  cat "$P/volatile/fstab" >> "$T/etc/fstab"
  cp "$P/volatile/profile.sh" "$T/etc/profile.d/20-sparkle-volatile.sh" ;;
sparkle)
  mkdir -p "$OUT"
  rm -f "$OUT/image.sqfs"
  t0=$(date +%s%N)
  mksquashfs "$T/usr" "$T/opt" "$OUT/image.sqfs" -comp lz4 -Xhc -noappend -quiet -no-progress
  echo "image_build_ms=$(( ($(date +%s%N) - t0) / 1000000 ))"
  ST=$(mktemp -d); chmod 755 "$ST"   # its mode becomes the mode of / in the pack
  mkdir -p "$ST/.sparkle/bin" "$ST/.sparkle/lower" "$ST/.sparkle/park" \
    "$ST/.sparkle/upper/usr" "$ST/.sparkle/upper/opt" "$ST/.sparkle/work/usr" "$ST/.sparkle/work/opt" \
    "$ST/usr/bin" "$ST/usr/sbin" "$ST/usr/lib/wsl/drivers" "$ST/usr/lib/wsl/lib" "$ST/opt" "$ST/etc"
  install -m 755 "$BB" "$ST/.sparkle/bin/busybox"
  install -m 755 "$P/stub/mount" "$ST/usr/bin/mount"
  install -m 755 "$P/stub/ldconfig" "$ST/usr/sbin/ldconfig"
  ln -s /.sparkle/bin/busybox "$ST/usr/bin/sh"
  cp "$P/stub/init.sh" "$ST/.sparkle/init.sh"
  echo "$OUT/image.sqfs" > "$ST/.sparkle/image"
  # S18: UPPER=<WSL path of the upper file> keeps the writes over /usr, /opt, /etc and /var/lib in
  # their own sparse ext4 file. The host creates it empty and sparse (fsutil sparse setflag +
  # fsutil file seteof); init.sh formats it on first boot. Reset = recreate that file.
  [ -n "${UPPER:-}" ] && echo "$UPPER" > "$ST/.sparkle/upper-img"
  cp -a "$T/var/lib/dpkg" "$ST/.sparkle/dpkg.seed"
  printf '[user]\ndefault=dev\n[boot]\ncommand = /.sparkle/bin/busybox sh /.sparkle/init.sh\n' > "$ST/etc/wsl.conf"
  cd "$T"
  tar --numeric-owner --xattrs --xattrs-include='*' -cpf "$OUT/seed.tar" \
    --exclude='./usr/*' --exclude='./opt/*' --exclude='./etc/wsl.conf' .
  tar --numeric-owner -rpf "$OUT/seed.tar" -C "$ST" .
  rm -rf "$ST"
  echo "image_bytes=$(stat -c %s "$OUT/image.sqfs") seed_bytes=$(stat -c %s "$OUT/seed.tar")" ;;
esac
