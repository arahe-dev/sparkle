# Applied once, in a chroot, to the extracted image before any variant is made, so every
# variant starts from byte-identical system files.
set -eu
id dev >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo dev
echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev; chmod 440 /etc/sudoers.d/dev
cat > /etc/profile.d/10-sparkle-env.sh <<'P'
export GALLIUM_DRIVER=d3d12
export MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA
if [ -n "${BASH_VERSION:-}" ] && [ -f /opt/ros/jazzy/setup.bash ]; then . /opt/ros/jazzy/setup.bash; fi
P
# Fail fast on dead mirrors (packages.ros.org is unreachable from the test network).
printf 'Acquire::http::Timeout "10";\nAcquire::https::Timeout "10";\nAcquire::Retries "1";\n' > /etc/apt/apt.conf.d/90sparkle
printf '[user]\ndefault=dev\n' > /etc/wsl.conf
rm -f /etc/resolv.conf
