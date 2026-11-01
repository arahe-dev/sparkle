# Results: Sparkle layout vs plain WSL

Benchmark spikes S10–S17, run 2026-10-30/31.
- Every number below comes from [bench/results/summary.md](../bench/results/summary.md).
- That summary is generated from the raw measurements in [bench/results/raw/](../bench/results/raw).
- How the runs were made fair, and what they don't show, is in [methodology.md](methodology.md). Read that page before quoting any of this.

**Machine:**
- Windows 11 Home, i7-13650HX, 48 GB RAM, Samsung NVMe, RTX 4060 Laptop GPU
- WSL 3.0.3, kernel 6.18.54

**Software:** `ros:jazzy-ros-base` (Ubuntu 24.04 + ROS 2 Jazzy, 599 packages) in three variants. All three are cut from one extracted image, so `/usr` and `/opt` are byte-identical (S10):

| Variant | What it is |
|---|---|
| **plain** | The image imported as a normal WSL distro |
| **tuned** | plain + Sparkle's scratch-on-tmpfs settings, applied by hand with `/etc/fstab`. This is the control: plain vs tuned shows how much tmpfs alone does, and how big the run-to-run noise is. |
| **sparkle** | `/usr` + `/opt` as a read-only squashfs image file on NTFS + a small writable disk, with the same tmpfs settings |

![Disk space a ROS 2 pack takes on Windows](../bench/results/footprint.svg)

## Summary

| | plain | sparkle | Difference |
|---|---|---|---|
| Disk on Windows, fresh | 1,118 MB | **460 MB** | **−59%** |
| Disk after the test workload (still 599 packages) | 2,924 MB | **2,006 MB** | −31% |
| Disk after `wsl --manage --compact` | 2,252 MB | **1,571 MB** | −30% |
| Data really on the writable disk (`df`) | 1,053 MB | **50 MB** | System files live in the image |
| Back to the original 599 packages | apt purge to a list, or re-import | **reset: 1.7 s boot**, n=1 | See S15 for what reset does and doesn't clear |
| Start a stopped distro (VM up) | 536 ms | 640 ms | +103 ms |
| Start after `wsl --shutdown` | 1,706 ms | 1,864 ms | +159 ms |
| New login shell (sources ROS `setup.bash`) | 900 ms | 1,084 ms | +184 ms |
| Run a command in a running distro | 164 ms | 168 ms | Same |
| `import rclpy`, guest cache dropped | 470 ms | 845 ms | 1.8× slower |
| `import rclpy`, warm | 172 ms | 205 ms | +19% (+30% vs tuned) |
| Compile against rclcpp headers, cold / warm | 2.06 / 1.96 s | 3.85 / 1.98 s | 1.9× slower cold, same warm |
| `colcon build`, 5 packages | 20.2 s | 18.0 s | Same (ranges overlap) |
| `apt install` of 134 packages | 32.0 s | 34.0 s | +6% (n=3, ranges overlap) |
| Compatibility checks | 18/18 | **18/18** | Same |
| Cold starts that came up correctly | 20/20 | **20/20** | No failures |
| 4 terminals opened at once, stopped distro | 20/20 | **20/20** | No failures |
| VM killed mid-`apt install`, then `dpkg --configure -a` + `apt-get install -f` | recovered | **recovered** | n=1 each |
| `wsl --export` (backup), file data | 19.7 s, 939 MB | **1.5 s, 32 MB** | Sparkle's leaves out the 336 MB image |

**Bottom line:**
- **Sparkle wins on space.** A fresh pack takes 59% less disk. A used pack takes about 30% less, because system files stay in a fixed-size image.
- **Sparkle can reset the package set** in about 2 s. In this prototype, reset doesn't shrink the disk file or clean `/etc` and `/var`.
- **Sparkle loses on speed:**
  - about 0.1–0.2 s per cold start or new login shell
  - about 2× on the first read of many files after the guest cache is dropped (a Windows reboot is likely worse)
  - about 20% on warm Python/ROS command startup (30–37% vs tuned)
  - CPU-bound work (compiling, building) is the same.
- **Failures recover like plain WSL.** A VM killed mid-install was repaired by the usual `dpkg --configure -a` + `apt-get install -f` (n=1 per variant). The one Sparkle-only failure tested, a missing image file, shows a confusing error (S16).
- **Disk growth is not solved.** The writable disk keeps its high-water mark like any WSL disk, and compaction gains are lost on the next heavy use. The fix is designed (S18) but not measured.

## S10 — Same bytes in every variant

Before comparing anything, S10 checks that the variants really hold the same system. It fingerprints `/usr` and `/opt` in each booted distro:
- the sorted metadata of every entry (path, type, mode, owner, link target, file size)
- the sha256 of every file's content

WSL's own mounts under `/usr` are excluded. `/etc` differs on purpose: each variant has its own boot and tmpfs settings.

| | plain | tuned | sparkle |
|---|---|---|---|
| Entries | 38,516 | 38,516 | 38,516 |
| Metadata hash | `ebb8feac4d2b5dc0` | `ebb8feac4d2b5dc0` | `ebb8feac4d2b5dc0` |
| Content hash | `b4173a482cb02bd8` | `b4173a482cb02bd8` | `b4173a482cb02bd8` |
| Import time | 3.1 s | 6.0 s | **1.05 s** (the seed only) |
| Disk at rest | 1,118 MB | 1,107 MB | **460 MB** = 336 MB image + 124 MB disk |

- Building the image and seed takes 13.7 s.
- In Sparkle v1 that build happens once, in CI, and users download the result.

**This check caught four bugs in the prototype.** An earlier version failed it. They're fixed now:

1. **WSL's kernel mounts were hidden.** WSL 3.0.3 mounts the kernel modules, headers and `perf` tools under `/usr` (`/usr/lib/modules/<kver>`, `/usr/src/linux-headers-<kver>`, `/usr/lib/linux-tools/<kver>`). The overlay hid them. The boot script now parks every mount under `/usr` and `/opt` and restores it after mounting the overlay.
2. **`wslpath` and `wslinfo` were missing.** WSL creates them in `/usr/bin` at boot, which put them under the overlay. They're now re-linked.
3. **The root directory was mode 700.** The seed's `/` came from a `mktemp -d` directory, so non-root users couldn't `cd /`.
4. **Three directories were world-writable.** Directories re-created at boot came out mode 777, because the boot script runs with umask 0.

The fixes were applied to the live `spb-sparkle` and S10 re-run; see [methodology.md](methodology.md).

## S11 — Startup (n = 10 per cell, variants interleaved)

Timed from Windows: how long `wsl.exe` takes until a command runs inside the distro. The command fails if the image isn't mounted, so each timing also checks that the boot worked.

| Start | plain | tuned | sparkle |
|---|---|---|---|
| After `wsl --shutdown` (VM boot) | 1,706 ms | 1,750 ms | 1,864 ms |
| Distro stopped, VM up | 536 ms | 565 ms | 640 ms |
| Distro running | 164 ms | 168 ms | 168 ms |
| Login shell (sources ROS `setup.bash`) | 900 ms | 916 ms | 1,084 ms |

- All 120 measurements succeeded, including 20 of 20 cold starts per variant.
- Mounting the image costs about 0.1–0.16 s per cold start.
- Every new terminal pays about 0.18 s more, because `setup.bash` reads many small files through the overlay and squashfs.

## S12 — Tool speed (n = 5; cold = guest page cache dropped before each step)

Python, `ros2` and colcon steps run as the `dev` user through a login shell (`su - dev -c`), so their timings include sourcing ROS's `setup.bash`. A warm-up pass runs before the warm loop.

| | plain | tuned | sparkle |
|---|---|---|---|
| Read all of `/usr` + `/opt`, cold | 5.98 s | 6.57 s | 6.77 s |
| Walk metadata, `find` over `/usr` + `/opt`, cold | 709 ms | 733 ms | **419 ms** |
| Login shell + `import rclpy`, cold | 470 ms | 438 ms | 845 ms |
| Login shell + `ros2 pkg list`, cold | 603 ms | 569 ms | 1,225 ms |
| `g++ -fsyntax-only` on rclcpp headers, cold | 2.06 s | 2.06 s | 3.85 s |
| Read all, warm | 542 ms | 546 ms | 792 ms |
| Walk metadata, warm | 39 ms | 42 ms | 177 ms |
| Login shell + `import rclpy`, warm | 172 ms | 158 ms | 205 ms |
| Login shell + `ros2 pkg list`, warm | 252 ms | 219 ms | 299 ms |
| `g++` on rclcpp headers, warm | 1.96 s | 2.00 s | 1.98 s |

**How to read this:**
- **Noise floor.** plain and tuned have identical `/usr`, so their gap is noise plus tmpfs. Here it's up to 15% (warm `ros2 pkg list`). Only read a sparkle gap well beyond that as real.
- **Cold reads cost more.** Squashfs has to decompress, so cold reads of many small files are about 1.8–2× slower: Python imports, `ros2`, C++ headers.
- **Cold metadata walks are faster.** Squashfs keeps metadata compact, so a cold `find` is 1.7× faster.
- **Warm compiling is the same.** It's CPU-bound.
- **Warm metadata-heavy work stays slower.** Python imports and `ros2` are about 20% slower than plain (30–37% vs tuned) and a `find` about 4.5× slower, because every lookup goes through the overlay.
- **The cold numbers likely understate the cost.** "Cold" means the guest cache was dropped. The Windows file cache, which holds the image file, could not be dropped. A first command after a Windows reboot is likely slower than shown.

## S13 — Building a ROS 2 workspace (n = 3)

`colcon build` of 4 C++ packages (an rclcpp node each) and 1 Python package, built from clean on the writable disk:

| plain | tuned | sparkle |
|---|---|---|
| 20.2 s (19.9–20.3) | 20.0 s (19.4–20.2) | 18.0 s (16.2–20.9) |

No measurable difference: the ranges overlap.

## S14 — Installing and removing packages (n = 3)

The package set is `mesa-utils python3-scipy ripgrep jq htop gdb`, which pulls in 134 packages (112 MB of `.deb`s).
- Installs run through `apt-get --no-download` from local copies.
- The one-time download happened before the timed runs. Its `apt update` took 121 s, mostly 10 s timeouts against `packages.ros.org`, which this network can't reach.

| | plain | tuned | sparkle |
|---|---|---|---|
| Install | 32.0 s (30.9–33.0) | 31.7 s (31.3–31.9) | 34.0 s (31.4–34.7) |
| Remove (`purge` + `autoremove`) | 20.2 s | 20.4 s | 20.5 s |
| Guest disk use after install | +533 MB | +509 MB | +509 MB |
| Packages `autoremove` left behind | 18 | 18 | 18 |
| `dpkg --audit` problems | 0 | 0 | 0 |

- apt and dpkg work correctly on the overlay.
- Sparkle's median install is 6% slower than plain, but with n=3 and overlapping ranges, that isn't established.
- `purge` + `autoremove` leaves the same 18 packages on every variant. The harness then purges them (untimed) to return to the exact 599-package baseline.
- The extra 24 MB on plain is apt's binary package cache, which tuned and sparkle keep in RAM.

## S15 — Disk growth, compaction and reset

By S15's start, every variant had been through S11–S14 and S17, which install and remove the S14 package set several times. Each was back to exactly the original 599 packages.

| | plain | tuned | sparkle |
|---|---|---|---|
| On Windows, fresh (S10) | 1,118 MB | 1,107 MB | 460 MB |
| On Windows, at S15's start | 2,824 MB | 2,724 MB | 2,006 MB |
| … after 5 rounds of use | 2,924 MB | 2,791 MB | 2,006 MB |
| Data really stored (`df` used) | 1,053 MB | 994 MB | 50 MB |
| After `wsl --manage <d> --compact` (about 7 s, distro stopped) | 2,252 MB | 2,196 MB | 1,571 MB |
| RAM held by the tmpfs paths | 0 | 100 MB | 100 MB |

Each round:
1. replays `apt update`
2. installs the S14 set
3. builds the workspace and runs a ROS node for 8 s
4. imports SciPy and rclpy
5. removes the packages, runs `apt-get clean`, and deletes the build output

What this shows:
- **Disk files track their peak, not their contents.** Every disk is 2–3 GB while holding 0.05–1 GB of data. After the first heavy use, more rounds add little: +100 MB plain, +67 MB tuned, 0 sparkle.
- **Compaction is partial and temporary:**
  - It takes back 0.4–0.7 GB, and repeats the same result run to run: 2,252 / 2,196 / 1,571 MB here, against 2,253 / 2,187 / 1,570 MB in an earlier run.
  - It leaves more than 1 GB of empty space in each disk.
  - The next heavy use grows it straight back. After the earlier compaction, re-running S17 (one install and removal) took the disks back to 2,824 / 2,724 / 2,006 MB.
- **Sparkle's lead comes from the image alone.** Its writable disk grows like any other: 1,235 MB of file for 50 MB of data. Sparkle stays about 0.7–0.9 GB smaller only because the system files never enter that disk.

**Reset (Sparkle only, n=1):**
1. Left the 134 packages installed (733 total).
2. Ran reset: touched `/.sparkle/reset` and restarted the distro.
3. The next boot took 1.7 s.
4. Result: 599 packages, and an upper layer of 15 bytes (effectively empty).

What the prototype's reset doesn't do yet:
- Files packages wrote to `/etc` and `/var` stay (configs, alternatives links, state). The design's fix is to overlay those too.
- The disk file doesn't shrink.

On plain WSL, the same package set comes back by purging to a saved list (what this harness does, leaving those `/etc` and `/var` remnants too) or by re-importing (which loses `/home`).

## S16 — Failure modes

What happens when things go wrong, and does the pack recover? Script: [bench/s16-robust.sh](../bench/s16-robust.sh). It kills the WSL VM 6 times when run in full.

**Four terminals opened at once on a stopped distro** (5 rounds per variant): 4 of 4 came up with the image mounted in every round, on all three variants.

**Power cut during `apt install`** (n = 1 per variant): the harness starts the S14 install (134 packages), waits until `dpkg` is running, waits 1 s more, then runs `wsl --shutdown`.

| | plain | tuned | sparkle |
|---|---|---|---|
| Cut at (dpkg seen running) | 8.0 s | 7.2 s | 8.4 s |
| Boots afterwards, image mounted | yes | yes | yes |
| New packages fully installed / half-done | 6 / 2 | 5 / 3 | 7 / 1 |
| `dpkg --audit` lines before repair | 12 | 10 | 8 |
| `dpkg --configure -a`, `apt-get install -f`, `apt-get check` | all rc 0 | all rc 0 | all rc 0 |
| `dpkg --audit` lines after repair | 0 | 0 | 0 |
| Same install run again, on the repaired system | rc 0 | rc 0 | rc 0 |
| Back at the 599-package baseline afterwards | yes | yes | yes |

- The cut really landed mid-install: on every variant, 8 of the 134 packages the install adds were fully or partly installed afterwards.
- Sparkle's overlay recovered the same way as a plain ext4 root. The standard repair (`dpkg --configure -a`, then `apt-get install -f`) was enough, and nothing Sparkle-specific was needed. `dpkg --audit` was checked only after both steps, so this doesn't show which one did the work.
- `wsl --shutdown` kills the VM, not the host. Writes the VM had already handed to Windows may still have reached the disk. A real power loss of the laptop was not tested.
- Each cut lands at one moment in the install, so n = 1 per variant shows that recovery *can* work, not that it always does.

**Image file missing** (sparkle only; the image was moved away, then put back):
- What the user sees, 1.9 s after launching: `execvpe(/bin/bash) failed: No such file or directory`. This doesn't say what is wrong. WSL starts the shell before the boot script has given up waiting for the image.
- The boot log does name the cause: `IMAGE MISSING: <path>`, logged after the boot script's 5 s wait.
- With the image back in place, the pack boots and the image mounts again (n=1). The writable disk was not checked separately.

**`wsl --export`** (what most WSL users do for backups):

| | plain | tuned | sparkle |
|---|---|---|---|
| Time | 19.7 s | 18.8 s | **1.5 s** |
| Entries in the archive (files, dirs, links) | 41,521 | 41,646 | 5,229 |
| File data (sum of member sizes, not the archive size) | 939 MB | 879 MB | **32 MB** |

- Sparkle's export holds only the writable disk: `/etc`, `/var`, `/home` and anything installed over the image. The image (336 MB, S10) is not in it. **A Sparkle backup is that export plus the image file**, or the image's name, if it can be pulled again.
- Restoring an export with `wsl --import` was not tested for any variant.

An earlier full run of S16 had a test bug. Its power cut fired 6 s after starting the install, but copying the `.deb` files to RAM takes longer than that, so dpkg had never started (`/var/log/dpkg.log` showed no activity; those rows were replaced by the re-run and not kept). It also read the boot log before the "image missing" line was written. Both were fixed, and only those two sections were re-run. The concurrent-start and export rows come from the first run.

## S17 — Compatibility (every check on every variant)

All 18 checks pass on all three variants:
- default user, passwordless sudo
- `cmd.exe` interop, `/mnt/c`, `wslpath`, `wslinfo`, DNS
- WSLg X11 socket, WSLg Wayland socket (checked in a real `wsl.exe` user session)
- `nvidia-smi -L` (RTX 4060), `/dev/dxg`, OpenGL renderer = D3D12 (NVIDIA)
- `ros2` CLI (194 packages), ROS 2 pub/sub
- SciPy, gdb
- `dpkg --audit` clean, `apt-get check`

Notes:
- A 19th, informational row records `/tmp`'s type: tmpfs on tuned/sparkle; on plain, `/tmp` is part of the root disk. WSLg's X11 socket works with tmpfs `/tmp`.
- **Not tested:** CUDA compute (only `nvidia-smi` device listing), VS Code Remote-WSL, Windows Terminal profiles, systemd, Docker, RViz/Gazebo.

Earlier runs of S17 had three test bugs, fixed before these results:
- WSLg checks ran through `su`, which drops `DISPLAY`.
- `cmd.exe` swallowed the rest of the test script from stdin.
- Two "ping/capabilities" checks could not fail, because this image has no `ping`. They were removed.

## Second image: `python:3.12-bookworm` (Debian 12, no ROS)

Does the layout hold for an image that isn't Ubuntu or ROS? Run 2026-10-31 with `bash bench/run-python.sh`, same machine.
- Numbers come from [bench/results-python/summary.md](../bench/results-python/summary.md), generated from [bench/results-python/raw/](../bench/results-python/raw).
- Image: `python:3.12-bookworm@sha256:034c3e9d…317a0` (linux/amd64), a 964 MB tree with Python 3.12.16 in `/usr/local` and gcc.
- **Provisional.** Three other benchmark sessions shared the WSL VM and laptop during these runs. Variants were interleaved, so the load hit all three, but the absolute times are noisier than the ROS runs.
- No `wsl --shutdown`, so there are no VM-cold rows. n = 5 per cell.
- S11 and S12 were re-run at 22:37–22:40, once the other sessions were idle and C: had space again. The tables show that re-run. The first run (S11 at 22:20, S12 at 22:30) is in git history at commit f998d24, `bench/results-python/raw/`.
- **Not run (time box):** S11 VM-cold, S13 build, S14 apt timing, S15 growth/compaction/reset, S16 failure modes, offline `.deb` install, restore onto a second PC.
- Limits are in [methodology.md](methodology.md#second-image-python312-bookworm-and-s20-exportrestore).

No change to `proto/` was needed. The stub, `init.sh` and the build script worked as-is on Debian. The harness change is image-profile knobs: probe file, guest scripts, tree path, and no VM restarts. The defaults are the ROS image's.

| Headline | ROS image (above) | Python image | Holds? |
|---|---|---|---|
| Same bytes in every variant (S10) | yes | **yes**: 27,542 entries, meta + content hashes equal | yes |
| Disk on Windows, fresh: plain → sparkle | 1,118 → 460 MB, **−59%** | 1,221 → 526 MB, **−57%** (412 MB image + 113 MB disk) | yes |
| Start a stopped distro (VM up) | 536 → 640 ms, +103 ms | 490 → 713 ms, **+223 ms** (wide ranges: plain 458–969, sparkle 519–935 ms). The first run, at 22:20, gave 608 → 703, +95 ms | yes, cost possibly larger |
| Run a command in a running distro | same | 193 vs 195 ms, same | yes |
| New login shell | +184 ms (ROS `setup.bash` reads from the image) | 197 vs 181 ms, no penalty (nothing to source) | n/a |
| Walk metadata, cold | 0.59× (faster) | 413 → 141 ms, **0.34×** (faster) | yes |
| Read all of `/usr` + `/opt`, cold | 1.13× | 5.23 → 7.30 s, **1.40×** | yes, a bit worse |
| Main tool, cold | `import rclpy` 1.8×; `g++` on rclcpp 1.9× | `gcc` small C file 112 → 367 ms, **3.3×**; vs tuned: stdlib import 1.7×, `pip --version` 4.5× | yes, worse |
| Main tool, warm | `g++` same; `import rclpy` +19% | `gcc` 28 vs 27 ms, same; stdlib import 75 vs tuned 71 ms (+6%); pip same | yes |
| Walk metadata, warm | 4.5× (39 → 177 ms) | 2.3× (25 → 57 ms) | yes |
| Compatibility (S17) | 18/18 | **18/20 on every variant**. The 2 failures are the same on all three (see below) | yes |

**So the result is not ROS-specific.** The disk saving, a start-time cost, and the "slower cold, same warm" shape all repeat on a Debian image with a different layout (`/usr/local`, empty `/opt`).

S12 (tool speed, ms, median of 5):

| | plain | tuned | sparkle |
|---|---|---|---|
| Read all of `/usr` + `/opt`, cold / warm | 5,229 / 490 | 4,973 / 490 | 7,304 / 675 |
| Walk metadata, cold / warm | 413 / 25 | 420 / 25 | 141 / 57 |
| Login shell + import 11 stdlib modules, cold / warm | 452 / 348 | 135 / 71 | 235 / 75 |
| Login shell + `pip --version`, cold / warm | 698 / 541 | 192 / 130 | 871 / 131 |
| `gcc -O2` small C file, cold / warm | 112 / 28 | 79 / 29 | 367 / 27 |

**Why plain is slow on Python here:** on this image, `plain` is 4–5× slower than tuned *and* sparkle on warm Python steps (348 vs 71–75 ms). The official `python` image deletes its compiled `.pyc` files (0 under `/usr/local/lib/python3.12`, checked after the run), and user `dev` can't write there. So on plain, Python recompiles every module it imports, on every run. Tuned and sparkle set `PYTHONPYCACHEPREFIX` to `/tmp` (part of the tmpfs settings), so their compiled cache survives between runs. This is a real-world benefit of the tmpfs settings on images built like this, not of the image layout. The fair comparison for Python steps is therefore sparkle vs **tuned**: 1.7–4.5× slower cold, about the same warm. Cold sparkle times have wide ranges (for example `gcc` 188–681 ms).

S17: all three variants pass the same 18 checks:
- default user, `cmd.exe` interop, `/mnt/c`, `wslpath`, `wslinfo`, DNS
- `nvidia-smi -L`, `/dev/dxg`, WSLg X11 and Wayland sockets
- Python 3.12.16, pip 25.0.1, stdlib (sqlite 3.40.1, OpenSSL), `venv`, gcc hello-world
- `dpkg --audit` clean, `apt-get check`

Two checks fail, and they fail identically on all three variants:
- `gpu_opengl_d3d12`: this image has no `glxinfo`. Expected.
- `apt_install_jq`: `apt-get update` failed (`Some index files failed to download`, rc=100). This is the network, not the layout. The offline `.deb` install that S14 measures on the ROS image was not repeated here.

### Export and restore (S20)

S16 timed `wsl --export` but never restored a backup. S20 exports each variant, imports it as a new distro and boots it. It ran on the Python image; the steps don't depend on the image.

| | plain | sparkle |
|---|---|---|
| Export stream size | 1,047.5 MB | **22.7 MB** |
| Export piped into `wsl --import` | 25.0 s | 1.6 s |
| Restored distro boots, image mounted, `python3 --version` runs as `dev` | yes (693 ms) | **yes** (940 ms) |

What a Sparkle backup does and doesn't contain:
- **`wsl --export` of a pack does not contain the image.** It holds only the small writable disk: the seed, `/etc`, `/home`, `/var` and the overlay's upper layer. The 412 MB image is a separate file on NTFS. The pack finds it by the absolute path in `/.sparkle/image`.
- **The image still in place:** the restored pack works unchanged (row `restored_*`).
- **The image not at that path** (another PC, or the folder moved): boot fails. A command returns rc=1 in 380 ms, and `/.sparkle/boot.log` says `IMAGE MISSING: <path>`. This is the same failure as S16's missing image (row `moved_image_*`).
- **Fix:** put the image anywhere, write its WSL path into `/.sparkle/image`, then `wsl -t <distro>`. The next start mounts it and Python runs (row `repointed_*`, 667 ms). The write uses `/.sparkle/bin/busybox`, because nothing under `/usr` exists while the image is missing.

Backup procedure for a Sparkle pack, as tested here (n = 1 per case; a restore onto a second PC was not tried):

```
wsl --export <pack> pack.tar                  # small: user data + writable layer
copy <image.sqfs> to the backup next to it      # the image is NOT in pack.tar
# restore:
wsl --import <pack> <dir> pack.tar --version 2
wsl -d <pack> -u root --exec /.sparkle/bin/busybox sh -c 'echo /mnt/c/<new path>/image.sqfs > /.sparkle/image'
wsl -t <pack>
```

For the real tool, this means `sparkle export` should bundle the image, or record its digest so the image can be re-fetched. It should also re-point `/.sparkle/image` on import.

What went wrong during these runs, recorded rather than hidden:
- **The first restore of `plain` came out broken** (no `dev` user, rc=127). C: had filled to 100% during its import: the 1 GB export tar was written while the shared disk was nearly full. After freeing space, S20 streamed the export straight into the import (no tar on disk) and restored plain again as `spb2i-restore2-plain`. The plain row above is from that second import. A full disk during `wsl --import` gives a distro that imports "successfully" but is unusable.
- Two test bugs were fixed and the affected steps re-run. The first S12 C program didn't compile (rc=1 on every variant). The first S20 re-point step called a bare `cat` that doesn't exist before the image is mounted.

## S18 — Reclaimable upper layer (provisional: n = 1 per stage, other sessions running)

**Question:** if the overlay's upper layer lives in its own file, does reset give the space back to Windows?

Two packs were built from the same `image.sqfs` + `seed.tar`:
- `old`: the upper layer is on the seed disk, as in S10–S17. Reset wipes it in place.
- `up`: the writes over `/usr`, `/opt`, `/etc` and `/var/lib` go to a sparse 64 GiB ext4 file next to the image (`/.sparkle/upper-img`, [proto/stub/init.sh](../proto/stub/init.sh)). Reset deletes that file and creates a new empty sparse one.

Footprint = image + seed `ext4.vhdx` + allocated bytes of the upper file (not its 64 GiB apparent size). Source: `bench/results/raw/s18.jsonl`, `bash bench/s18-reclaim.sh`.

| Windows-side footprint | old | up |
|---|---|---|
| fresh | 483 MB | 490 MB |
| after S14 install | 1,154 MB | 1,627 MB |
| after reset | **1,154 MB** | **490 MB** |
| after 2nd install | 1,322 MB | 1,857 MB |
| after 2nd reset | **1,322 MB** | **490 MB** |
| then `--compact` (distro stopped) | 818 MB | 568 MB |

- **Reset gives the space back, exactly, every time.** `up` returned to its fresh 490,393,600 bytes after both resets. `old` kept the high-water mark (1.32 GB after two rounds), as in S15.
- **Package state is clean after reset** on both: 599 packages, `dpkg --audit` empty, 0 packages beyond the baseline. On `up`, `/etc` and `/var/lib` are overlays too, so package configs and dpkg/apt state go with the file.
- **Basics still work** on `up` after each reset: `/mnt/c`, `wslpath`, `/dev/dxg`, and `ros2 pkg list` (194 packages, same as `old`).
- **But the upper file is wasteful while in use.** The install allocated 1.14 GB in the upper file, versus 0.67 GB of growth on `old`'s disk for the same packages. Likely cause: ext4's lazy inode-table init zeroes the inode tables of the whole 64 GiB filesystem in the background after mount, and every zeroed block is allocated on NTFS. The idle upper file kept growing (568 MB footprint after the compaction step, up from 490 MB at boot), which fits that cause. Not yet fixed. Next things to try: `mount -o noinit_itable`, fewer inodes (`mke2fs -N`), or a smaller filesystem that grows.
- **Installs were slower:** 60.5 s on `up` vs 35–40 s on `old` (n = 2, other sessions running). Writes go through a loop device on a file on 9p/drvfs.
- **Startup:** 811 ms vs 720 ms (n = 3, ranges overlap: 801–817 vs 611–1,007). Inconclusive.
- **`fstrim` before `--compact` added nothing.** On `old`, `--compact` alone took the disk from 986 MB to 482 MB, and `fstrim` + `--compact` left it at 482 MB. Compaction ran with only the distro stopped (`wsl -t`), not the VM. It still left `old` 335 MB above fresh.
- **Findings on the way:**
  - A file extended from inside WSL (`truncate` on drvfs) is allocated in full on NTFS. A 64 GiB `truncate` failed with "No space left on device". The host has to create the file sparse (`fsutil sparse setflag` + `fsutil file seteof`), so a guest-only reset can't recreate it. In the prototype, `touch /.sparkle/reset` on an upper-file pack deletes the file, and the next boot falls back to the seed disk until the host makes a new one.
  - The cached `seed.tar` imports with `/` at mode 700, so user `dev` got `chdir(/) failed 13`. `chmod 755 /` was applied to both S18 distros before the run. Design item 1 says this was fixed in `proto/`, but the cached seed predates the fix.

## What changes in the design

1. **Boot (done in [proto/](../proto)):** park and restore all WSL mounts under `/usr` and `/opt`; re-link `wslpath`/`wslinfo`; `umask 022`; seed `/` at mode 755.
2. **The writable disk needs its own reclaim story.** S15 shows a high-water mark, plus compaction that is partial and temporary. Proposal for spike S18:
   - put the overlay's upper layer (user-installed packages) on its own small disk, so that reset *deletes that file* and the space returns at once, guaranteed
   - overlay `/etc` and `/var/lib` the same way, so reset also clears package configs
   - keep `/home` on the seed
   - also measure `fstrim` before `--compact`
3. **First-read and warm-lookup cost** (about 2× cold; 20–37% warm for Python/ROS) is the main speed cost. Options for spike S19:
   - background pre-read of `/opt/ros` and `/usr/include` after boot (costs RAM)
   - erofs, or squashfs with larger blocks or no compression for hot trees
   - measuring a host-cold first read
4. **A missing image must fail loudly** (S16). The user saw only `execvpe(/bin/bash) failed`. The `sparkle` CLI should check the image before it launches a pack and say what is missing and how to get it back. Backups need the image too, or its name, since `wsl --export` leaves it out.
5. **tmpfs paths cost about 100 MB of RAM** and empty the apt lists on every boot, so Sparkle's package command must refresh them. Shipping current lists with each image avoids a slow first `apt update`.
