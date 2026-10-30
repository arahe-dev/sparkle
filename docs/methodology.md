# Methodology

This page explains how the numbers in [results.md](results.md) were produced. It also lists what they don't show. If you find a flaw, open an issue: the harness is meant to be re-run and argued with.

## The question

The question is whether a WSL distro laid out the Sparkle way is better or worse than a normal WSL distro holding the same software. Sparkle's layout is a read-only image on NTFS plus a small writable disk.

## Three variants, one set of bytes

The test builds three distros from **one** extracted image tree. The tree is `ros:jazzy-ros-base` (linux/amd64), flattened with `crane export`. Before the tree is split, a setup script ([proto/common-setup.sh](../proto/common-setup.sh)) applies the same changes to every variant:
- a `dev` user with passwordless sudo
- the GPU environment variables
- sourcing the ROS setup script
- 10 s apt timeouts

| Variant | What it is | Who it stands for |
|---|---|---|
| `plain` | The tree, streamed into `wsl --import` | Anyone using WSL today, e.g. `docker export \| wsl --import` |
| `tuned` | `plain` + Sparkle's scratch paths on tmpfs, using only `/etc/fstab` and `/etc/profile.d` | A careful WSL user who knows the tricks. This isolates how much of Sparkle's win comes from tmpfs alone. |
| `sparkle` | `/usr` and `/opt` as an lz4hc squashfs image on NTFS, plus a seed disk holding the rest (`/etc`, `/var`, `/home`) and the boot stub ([proto/](../proto)). It has the same tmpfs paths as `tuned`. | The layout Sparkle v1 would create |

**Proof that the variants hold the same files:** S10 fingerprints `/usr` and `/opt` in every variant after boot. It hashes:
- the sorted metadata of every entry: path, type, mode, owner, size, link target
- the content of every regular file

Results are only compared if those fingerprints match. Where they don't match, S10 reports it.

## What "tmpfs paths" means

The volatile set ([proto/volatile](../proto/volatile)) is:
- `/tmp`, `/var/lib/apt/lists`, `/var/cache/apt`
- `PYTHONPYCACHEPREFIX`, `ROS_LOG_DIR` and `XDG_CACHE_HOME`, pointed into `/tmp`

These paths hold scratch that tools can recreate. The trade-off is RAM use, plus losing the apt lists on every reboot, so `apt install` needs an `apt update` first. S15 records the RAM cost.

## How runs are made fair

- **Interleaving.** For every repeated measurement, the variant order rotates each run (plain → tuned → sparkle, then tuned → sparkle → plain, …). Thermal drift and background work spread across all variants instead of landing on one.
- **Medians.** Tables show the median with min–max and the run count. Raw values are in `bench/results/raw/*.jsonl`, one JSON object per measurement.
- **No network in timed parts.** Package installs use `.deb` files downloaded once (S14 prep) and copied to `/dev/shm`. `apt update` is replayed from a captured copy of the lists, so every variant writes the same bytes.
- **Startup probe.** The startup probe is `test -e /opt/ros/jazzy/setup.bash`. It fails if the image isn't mounted, so every timing also checks that the pack booted correctly.
- **Host-side timing.** Times are measured from Git Bash on Windows around `wsl.exe`, so they include the cost of starting `wsl.exe`. That cost is the same for every variant and is what users actually experience.

## Known limits (threats to validity)

- **One machine, one image.** All numbers come from a single laptop (see `bench/results/machine.txt`) and the ROS base image. A slower disk or a much bigger image would change the absolute numbers. The direction should hold, but that isn't proven.
- **"Cold" means guest-cold.** Without admin rights, the Windows file cache can't be dropped. The guest page cache *is* dropped before each cold step. The image is a file on NTFS, so its blocks can still sit in the Windows cache, which flatters `sparkle` on cold reads. The very first read after a reboot is not measured here; the S7 spike measured a fully cold read at 4.6 s vs 3.7 s.
- **Synthetic use.** S15's "rounds of use" are a scripted mix: install packages, build a workspace, run a node, import Python modules, then clean up. Real use is messier. That likely means *more* growth than S15 shows, because untidy users leave more behind.
- **Rough edges in the prototype.** The prototype uses shell scripts plus a static busybox (sha256 is recorded in the S10 results). A real Sparkle would generate the same files from Rust.
- **Not tested:**
  - VS Code Remote-WSL attach
  - Windows Terminal profile creation
  - systemd (the ROS image doesn't ship it)
  - Docker/Podman inside a pack
  - RViz/Gazebo
  - images other than ROS base

## Reproduce

Requirements:
- Windows 11 with WSL 2 (3.0.3 was used)
- Git Bash
- Python 3
- `crane`
- a helper distro that has `mksquashfs` 4.6 or later
- a static busybox

Steps:

1. `crane pull --platform linux/amd64 ros:jazzy-ros-base image.tar`
2. `bash bench/run-all.sh image.tar` (about an hour). The test distros are named `spb-*`.
3. `python bench/summarize.py` regenerates `bench/results/summary.md` and the charts.

The harness never deletes anything. Remove the test distros yourself when you're done:

```
wsl --unregister spb-plain
wsl --unregister spb-tuned
wsl --unregister spb-sparkle
```

Then delete `%USERPROFILE%\sparkle-bench`.
