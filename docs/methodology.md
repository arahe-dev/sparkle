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
- **Only the final run of each spike is in the raw data.** Each script replaces its own file when it runs. Earlier and failed runs are described in [results.md](results.md) and in the git history, not kept as data.
- **The noise floor is plain vs tuned.** Those two variants have byte-identical `/usr` and `/opt`, so for reads of the image, any gap between them is run-to-run noise plus the tmpfs settings. Read a sparkle-vs-plain gap against that.
- **No network in timed parts.** The package lists and `.deb` files were downloaded once, in `plain` (S14 prep). After that:
  - Installs run `apt-get install --no-download` from local copies. Plain `dpkg -i *.deb` was tried first and dropped, because it mis-orders pre-dependencies (`systemd-sysv` before `systemd`).
  - `apt update` is replayed from the captured lists, so every variant writes the same bytes.
- **Same package set at every step.** After each removal, any package not in the image's original list is purged, so every variant starts each step from exactly the same 599 packages. The original list comes from Sparkle's untouched seed copy of the dpkg database.
- **Startup probe.** The startup probe is `test -e /opt/ros/jazzy/setup.bash`. It fails if the image isn't mounted, so every timing also checks that the pack booted correctly.
- **Host-side timing.** Times are measured from Git Bash on Windows around `wsl.exe`, so they include the cost of starting `wsl.exe`. That cost is the same for every variant and is what users actually experience.

## Known limits (threats to validity)

- **`apt update` timing is not a mirror speed.** The test network can't reach `packages.ros.org`. With 10 s apt timeouts, the one-time 121 s `apt update` is mostly spent waiting on that dead repository.
- **Timed user commands include a login shell.** Python, `ros2` and colcon steps run through `su - dev -c`, so each timing includes a login shell sourcing ROS's `setup.bash`. That cost is the same for every variant.

- **History differs a little between variants.**
  - The variants ran the same steps in the same order. But `plain` also did the one-time `apt update` and download (55 MB of lists written to its disk).
  - A first attempt at S14/S15/S17 was interrupted and left half-finished installs. Those were purged back to the 599-package baseline before the reported runs.
  - Both events can only have *grown* `plain`'s disk relative to the others. That is why S15 reports `df` (data really stored) next to the file size, and why the fresh sizes come from S10, before any of it.
- **The Sparkle distro was patched in place.** The S10 equivalence check found four prototype bugs. They were fixed in the live `spb-sparkle` (boot script, two directory modes, `/` mode) instead of rebuilding it. S10 was then re-run and matched. `proto/` contains the fixed version, so a fresh build gets the same result without patching.

- **"Power cut" means a VM kill.** S16 cuts with `wsl --shutdown` while dpkg is running. That kills the Linux VM, but Windows keeps running, so writes already handed to Windows can still land. Pulling the laptop's power was not tested. There is one cut per variant, each at a single moment in the install.
- **Two S16 sections were re-run.** In the first full run, the power cut came before dpkg started, and the boot log was read too early. Only those sections were fixed and re-run (`bash bench/s16-robust.sh power_cut` / `image_missing`), so their rows come from a later run than the concurrent-start and export rows.

- **S18 measures each footprint stage once.** Footprints are file sizes and don't depend on load; the install timings are n = 2 and startup n = 5. Both packs come from `bench/s18-setup.sh`: the S10 seed re-packed with today's `proto/stub` scripts and `/` at 755. The upper file is 64 GiB sparse, and its allocated size is read with Git Bash `du` (allocated, not apparent). The lazy-inode-init explanation for its extra allocation is a likely cause, not a tested one.

- **S19's cache drops are VM-wide.** In the quiet re-run nothing else used the VM, so they only affect S19 itself. Variants are interleaved. "Cold" here is guest-cold, as in S12: the image files' blocks could still be in the Windows file cache.
- **S19 measures variants in chroots, not separate distros.** All variants are bind-mounted roots inside one distro, sharing its `/etc` and kernel. That isolates the filesystem, but it is not a booted pack. `sqraw` and `sqraw, no overlay` likely share one loop device, so their caches are shared in warm runs. The erofs module is loaded by hand in `bench/s19-fixtures.sh`, with busybox `insmod` from the helper distro (it has no `kmod`). The `sq128` image is a copy of the S10 image, so it has no S19 build time. The distro imported from `seed.tar` had `/` at mode 0700, which breaks `su - dev`; the setup script sets it to 0755.

- **One machine, one image.** All numbers come from a single laptop (see `bench/results/machine.txt`) and the ROS base image. A slower disk or a much bigger image would change the absolute numbers. The direction should hold, but that isn't proven.
- **"Cold" means guest-cold.** Without admin rights, the Windows file cache can't be dropped. The guest page cache *is* dropped before each cold step. The image is a file on NTFS, so its blocks can still sit in the Windows cache, which flatters `sparkle` on cold reads. A truly cold first read after a Windows reboot has not been measured. The earlier S7 spike's 4.6 s vs 3.7 s was a different setup (`/usr` only), and its host-cache state wasn't recorded.
- **Synthetic use.** S15's "rounds of use" are a scripted mix: install packages, build a workspace, run a node, import Python modules, then clean up. Real use is messier. That likely means *more* growth than S15 shows, because untidy users leave more behind.
- **Rough edges in the prototype.** The prototype uses shell scripts plus a static busybox (sha256 is recorded in the S10 results). A real Sparkle would generate the same files from Rust.
- **Not tested:**
  - VS Code Remote-WSL attach
  - Windows Terminal profile creation
  - systemd (the ROS image doesn't ship it)
  - Docker/Podman inside a pack
  - RViz/Gazebo
  - images other than ROS base (partly done since: see "Second image" below)
  - restoring a `wsl --export` backup (done since: S20 below)

## Second image (python:3.12-bookworm) and S20 export/restore

These runs live in `bench/results-python/` and come from `bash bench/run-python.sh <image.tar> <crane.exe>`. The same scripts run with an image profile set by environment variables; their defaults are the ROS image, so the main runs are unchanged:

| Variable | ROS default | Python run |
|---|---|---|
| `SPARKLE_PROBE` (file that exists only once the image is mounted) | `/opt/ros/jazzy/setup.bash` | `/usr/local/bin/python3` |
| `SPARKLE_GUEST` (guest-script suffix) | none | `-python` (`bench/guest/s12-python.sh`, `s17-python.sh`) |
| `SPARKLE_NO_SHUTDOWN` | unset | `1`: restart only our own distros with `wsl -t` |
| `SPARKLE_TREE` | `/mnt/wsl/spb-tree` | `/mnt/wsl/spb2i-tree` |

Limits that apply only to these runs:
- **The first run was on a shared, busy VM; the tables come from the quiet re-run.** See below.
- **No VM-cold numbers.** The harness keeps `SPARKLE_NO_SHUTDOWN=1` for this image (the first run shared the VM with other sessions), so S11 has only `distro_cold`, `warm` and `login_shell` rows. S10's "size at rest" is read after `wsl -t` of each distro, not after a VM shutdown.
- **Smaller scope than the ROS runs.** Only S10, S11, S12, S17 and S20 ran. No S13 (build), S14 (apt timing), S15 (growth over use) or S16 (failure modes). "Disk fresh" is S10's footprint after first boot.
- **Different check list.** S12 and S17 swap the ROS tools for Python/C ones (stdlib imports, `pip`, `venv`, `gcc`). There is no `sudo` check, because `python:*` images do not ship `sudo`. The WSLg/OpenGL user checks (`s17-user.sh`) still run; `glxinfo` is not in this image, so the OpenGL row fails on every variant by design.
- **`apt install` here is online** (`apt-get update` + `jq` from deb.debian.org), not from a local .deb set like the ROS S17. It depends on the network.
- **The image pull failed once** (first run). The first `crane pull` ended with `unexpected EOF` after 10 minutes on this network. It was re-run with a layer cache, pinned to the digest it had resolved: `python:3.12-bookworm@sha256:034c3e9d991f148d14c32ff8350286b91420baca7757d37819c7a9cc771317a0` (linux/amd64).
- **The shared disk filled up mid-run** (first run only). At 22:21, C: reached 100% while S20 wrote a 1 GB export tar. The plain distro imported then had no `dev` user. S20 now streams `wsl --export` into `wsl --import` with no tar on disk, and plain was restored again under a new name (`spb2i-restore2-plain`). The broken first import was left in place, not deleted. S10 and S17 had finished before the disk filled. S11 finished at 22:20:36, at the edge of it, so S11 and S12 were both re-run at 22:37–22:40 with the disk at 19 GB free and the other sessions idle; the results use the re-run. The two S11 runs disagree on the start-time cost (+95 ms, then +223 ms; n = 5 each, wide ranges). Treat it as "about 0.1–0.2 s". The quiet re-run measured +144 ms.
- **On this image, plain is the odd one out on warm Python steps** (about 4× slower than tuned and sparkle). Cause: the image ships no `.pyc` files and `dev` can't write them, so plain recompiles on every run, while tuned and sparkle cache them under `/tmp` via `PYTHONPYCACHEPREFIX`. The Python comparison in results.md is made against tuned.
- **S20 restore is n = 1 per case, on one PC.** "Image in a different folder" is simulated by rewriting `/.sparkle/image` to a folder with no image, then to a copy in a new folder. A restore onto a second PC was not tested.

## The quiet re-run (2026-11-01)

S18, S19, the second image and the CLI were first measured on 2026-10-31 while four benchmark sessions shared this PC and its WSL VM. All four were re-run on 2026-11-01, one after another:
- One `wsl --shutdown` at the start, then no other WSL use: no other benchmark sessions, and nothing driven by hand while the runs were going. Other Windows apps may still have been open.
- Order: S18 → second image (S10, S17, S12, S11, S20) → S19 → CLI. S19 and the CLI had to be re-launched after the second image, because of two harness bugs (no `modprobe` in the helper distro; the CLI test passed no `--image`). Neither bug touched a measurement.
- The helper distro was kept running from S19 to the end, to hold the erofs module and the tmpfs tree. It ran only `sleep` outside its own build steps.
- Scripts: `bench/s18-setup.sh`, `bench/s18-reclaim.sh`, `bench/run-python.sh`, `bench/s19-fixtures.sh`, `bench/s19-coldread.sh`, `bench/cli-e2e.sh`.
- Those setup scripts **replace their own test distros** (`spb-old`, `spb-up`, `s19-bench`, `sparkle-e2e`) by unregistering them first, unlike S10, which skips variants that already exist. They touch nothing else.
- The first runs' data is in git history (commits a31785d, a0cee85, 330ad8b, 83743a4). The quiet runs agree with them on every conclusion; the docs note where a number moved.

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
