# Fingerprint /usr and /opt: metadata (path, type, mode, owner, link target; size for files)
# and the content of every regular file. $1 = where to save the full listing (optional).
# Mounts WSL adds under /usr (GPU drivers, kernel modules/headers/tools) are not part of the
# image and are skipped. Directory sizes depend on the filesystem, so only file sizes count.
cd /
P=$(awk '$2 ~ "^/(usr|opt)/" {printf "-path %s -prune -o ", substr($2,2)}' /proc/mounts)
find usr opt $P -printf '%p|%y|%m|%U|%G|%l\n' -type f -printf '%p|size|%s\n' | LC_ALL=C sort > /tmp/.meta
echo "entries $(grep -vc '|size|' /tmp/.meta)"
echo "meta $(sha256sum < /tmp/.meta | cut -c1-16)"
find usr opt $P -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16 | sed 's/^/content /'
[ -n "${1:-}" ] && cp /tmp/.meta "$1/meta-$WSL_DISTRO_NAME.txt"
# Mounts WSL adds under /usr must be visible in every variant (they were hidden in an early
# sparkle prototype): list them so the results show it.
echo "wsl_mounts $(awk '$2 ~ "^/(usr|opt)/" {n++} END {print n+0}' /proc/mounts)"
