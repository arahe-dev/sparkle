# S19 image variants, cut from the same tree. Runs as root in the helper distro (needs
# unsquashfs, mksquashfs >= 4.6, mkfs.erofs). $1 = source image.sqfs, $2 = out dir.
# Leaves the tree at $T for the bench distro to copy as its plain-ext4 reference.
set -eu
SRC=$1 OUT=$2 T=/mnt/wsl/s19-tree
rm -rf "$T"; mkdir -p "$T"; unsquashfs -q -n -d "$T/root" "$SRC" >/dev/null
b() { local n=$1 s; shift; s=$(date +%s%N); "$@" >/dev/null; echo "$n build_ms $(( ($(date +%s%N) - s) / 1000000 ))"; }
rm -f "$OUT"/v-*
cp "$SRC" "$OUT/v-sq128.img"
b sq1m mksquashfs "$T/root/usr" "$T/root/opt" "$OUT/v-sq1m.img" -comp lz4 -Xhc -b 1M -noappend -quiet -no-progress
b sqraw mksquashfs "$T/root/usr" "$T/root/opt" "$OUT/v-sqraw.img" -noI -noD -noF -noX -noappend -quiet -no-progress
b erolz4 mkfs.erofs -zlz4hc "$OUT/v-erolz4.img" "$T/root"
b eroraw mkfs.erofs "$OUT/v-eroraw.img" "$T/root"
for f in "$OUT"/v-*.img; do n=${f##*/v-}; echo "${n%.img} image_bytes $(stat -c %s "$f")"; done
echo "plain tree_bytes $(du -sb "$T/root" | cut -f1)"
