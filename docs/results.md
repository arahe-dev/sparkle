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

## S19 — Removing the speed cost: image format and prewarm (n = 5, provisional)

**Provisional:** these runs shared the PC and the WSL VM with three other benchmark sessions, so they carry extra noise. Variants were interleaved, so the noise hits all of them, but read only large gaps as real.

Setup: one bench distro holds every variant side by side (`bench/guest/s19-setup.sh`). Each variant's `/usr` + `/opt` is cut from the same tree. The image variants are files on NTFS, loop-mounted under an overlay with a tmpfs upper, as Sparkle mounts them. `plain` is the same tree copied onto the distro's ext4. Commands run in a `chroot` of each variant, through `su - dev -c` like S12. S12's full-read row was left out to fit the time box. Medians:

| | plain ext4 | **sq128** (today) | sq1m | sqraw | **erolz4** | eroraw | sqraw, no overlay |
|---|---|---|---|---|---|---|---|
| Image size | (tree 860 MB) | 336 MB | 324 MB | 849 MB | **460 MB** | 865 MB | (849 MB) |
| `find` over `/usr` + `/opt`, cold | 718 ms | 385 ms | 427 ms | 272 ms | 831 ms | 870 ms | 301 ms |
| Login shell + `import rclpy`, cold | 469 ms | 991 ms | 1,151 ms | 1,265 ms | **682 ms** | 770 ms | 1,305 ms |
| Login shell + `ros2 pkg list`, cold | 603 ms | 1,241 ms | 1,554 ms | 1,238 ms | **1,049 ms** | 1,030 ms | 1,536 ms |
| `g++` on rclcpp headers, cold | 2.12 s | 4.00 s | 4.68 s | 4.28 s | **2.75 s** | 2.89 s | 4.85 s |
| `find`, warm | 39 ms | 98 ms | 177 ms | 96 ms | **35 ms** | 36 ms | 166 ms |
| `import rclpy`, warm | 153 ms | 224 ms | 197 ms | 231 ms | **168 ms** | 163 ms | 206 ms |
| `ros2 pkg list`, warm | 298 ms | 323 ms | 282 ms | 418 ms | **231 ms** | 234 ms | 284 ms |
| `g++` on rclcpp headers, warm | 2.08 s | 2.82 s | 2.42 s | 1.93 s | 1.95 s | 2.06 s | 1.96 s |

`sq128` = today's squashfs (lz4hc, 128 KiB blocks); `sq1m` = 1 MiB blocks; `sqraw` = squashfs with no compression; `erolz4` = erofs `-zlz4hc`; `eroraw` = erofs uncompressed. Image builds: squashfs 12–14 s, erofs 170–200 s (single-threaded `mkfs.erofs`).

**How to read this:**
- **The cold cost is squashfs, not compression.** Uncompressed squashfs is no faster than lz4hc, and 1 MiB blocks are slower. erofs on the same file, under the same overlay, cuts the cold gap to plain by 30–67%: `import rclpy` +213 ms instead of +522 ms, `ros2 pkg list` +446 ms instead of +638 ms, the header compile +0.63 s instead of +1.88 s. The kernel is built with `SQUASHFS_DECOMP_SINGLE` (one decompressor at a time), which may be part of it; that wasn't isolated.
- **The warm cost is squashfs too, not the overlay.** erofs under the overlay is level with plain when warm (`find` 35 vs 39 ms, `import rclpy` 168 vs 153 ms, inside the noise). Dropping the overlay from uncompressed squashfs (`sqraw, no overlay`) doesn't help. The overlay-lookup hypothesis is not supported.
- **Cold `find` is the one place squashfs wins** (385 vs 831 ms for erofs). erofs is about level with plain there.
- **Cold still isn't plain.** erofs leaves `ros2 pkg list` about 1.7× plain cold.
- **The warm `g++` row is noisy** (ranges up to 3.8–5.4 s in single runs). Don't read the warm compile differences.

### Prewarm (`proto/stub/prewarm.sh`)

It reads `/opt/ros`, `/usr/include` and the Python stdlib and `dist-packages` at `nice 19`. Each cell drops the guest cache first. "After" = prewarm ran to completion, then the command. "During" = prewarm started in the background and the command started at once (a command typed right after boot).

| | sq128 | eroraw |
|---|---|---|
| Time to warm | 1.9–2.1 s | 5.2–5.9 s |
| Page cache it adds | 524 MB | 330 MB |
| `import rclpy`: cold / after / during | 991 / 522 / **2,607** ms | 770 / 474 / **1,144** ms |
| `ros2 pkg list`: cold / after / during | 1,241 / 719 / **2,900** ms | 1,030 / 528 / **1,405** ms |
| `g++` on headers: cold / after / during | 4.00 / 3.78 / **5.74** s | 2.89 / 2.50 / **3.02** s |

- **Once it's finished, prewarm brings Python and ROS to about plain cold.** It barely helps `g++`, which also reads the compiler and libraries outside the prewarmed set.
- **While it's running, it makes things worse: 2–2.6× slower than cold.** The first command is the one a user notices, so prewarm hurts the case it was meant to fix.
- **It costs 330–524 MB of page cache.** On squashfs it's more, likely because the loop device caches the image file as well as the decompressed files. The kernel can reclaim it, but it's RAM taken at boot.
- One `eroraw` cache-delta sample came out negative (−363 MB): something else on the VM freed cache during that run. The other samples agree.

### Recommendation

- **Switch the image to erofs with lz4hc.** It removes all of the warm cost and most of the cold cost. Disk: 460 MB vs 336 MB, +124 MB (+37%) per image, which still leaves the image about half the size of the tree. Image builds are about 12× slower (170 s vs 14 s); `mkfs.erofs` has multithreaded options that weren't tried.
  - **A blocker first:** WSL's kernel builds erofs as a module (`CONFIG_EROFS_FS=m`), not built in. In this test it was loaded with `insmod` from another distro. Inside a pack booted from today's seed, `/usr/lib/modules/<kernel>` was missing, so the pack can't load it itself yet. The boot path must load `erofs.ko` from WSL's modules mount before the image mounts, or fall back to squashfs.
  - The erofs images were loop-mounted (util-linux sets up a loop for a regular file). erofs's file-backed mode (`CONFIG_EROFS_FS_BACKED_BY_FILE=y`) skips the loop device and wasn't tried; it may cut the double caching.
- **Don't turn prewarm on by default.** It slows the first command while it runs, and it costs 330–524 MB of RAM. It ships as opt-in: `init.sh` starts it only if `/.sparkle/prewarm.on` exists.

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
