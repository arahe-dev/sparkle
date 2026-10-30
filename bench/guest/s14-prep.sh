# S14 prep, root, once: fetch package lists and the test packages so every variant installs
# byte-identical .debs with no network in the timed part. $1 = bench dir (WSL path).
set -e
D=$1; PKGS="mesa-utils python3-scipy ripgrep jq htop gdb"
mkdir -p $D/debs/partial
s=$(date +%s%N); apt-get update >/dev/null 2>&1 || true
echo "apt_update_ms $(( ($(date +%s%N) - s) / 1000000 ))"
echo "apt_lists_bytes $(du -sb /var/lib/apt/lists | cut -f1)"
tar -C /var/lib/apt/lists -cf $D/lists.tar --exclude=./partial --exclude=./lock .
apt-get install -y --download-only -o Dir::Cache::archives=$D/debs $PKGS >/dev/null
rm -rf $D/debs/partial $D/debs/lock
echo "debs_count $(ls $D/debs/*.deb | wc -l)"
echo "debs_bytes $(du -cb $D/debs/*.deb | tail -1 | cut -f1)"
