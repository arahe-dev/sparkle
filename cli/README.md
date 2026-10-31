# sparkle CLI (v0.1, first working cut)

```
sparkle add <name> [--image <ref>]   pull an OCI image and make it a pack (WSL distro sparkle-<name>)
sparkle enter <name> [-- cmd...]     open a shell in the pack (or run cmd in a login bash)
sparkle ls                           list packs with on-disk size (image + vhdx) and image ref
sparkle reset <name>                 drop everything installed over the image (applies on next start)
sparkle eject <name>                 wsl --unregister the distro, then delete its pack folder
```

`add ros` defaults to `ros:jazzy-ros-base` (linux/amd64). Other names need `--image`.

## How `add` works

1. **Download**: `crane pull --platform linux/amd64 <ref>` to `SPARKLE_HOME\cache\<ref>.tar`. A second `add` of the same ref reuses the tarball.
2. **Flatten**: `crane export - -` piped into `tar -x` in a tmpfs at `/mnt/wsl/sparkle-build-<name>` inside the helper distro (`SPARKLE_TOOL_DISTRO`, default `sparkle-s1-ours2`, needs mksquashfs >= 4.6).
3. **Build**: the benchmark's own `proto/build-fixtures.sh` (`setup`, then `sparkle` stage), embedded in the binary byte-for-byte with `include_str!`, with the stubs, `proto/volatile/` and `proto/common-setup.sh`. So the pack is exactly what S10–S17 measured: lz4hc squashfs of `/usr` + `/opt`, plus a seed tar.
4. **Import**: `wsl --import sparkle-<name> SPARKLE_HOME\packs\<name> seed.tar --version 2`. The seed tar and build files are then deleted. The pack folder keeps `image.sqfs`, `ext4.vhdx` and `sparkle.meta`.

`enter` checks that `image.sqfs` exists before launching. Without it the user sees:

```
sparkle: the image for pack "ros" is missing: C:\...\packs\ros\image.sqfs
The pack's /usr and /opt live in that file, so sparkle-ros cannot start without it.
Fix: restore the file to that path, or rebuild the pack:
  sparkle eject ros
  sparkle add ros --image ros:jazzy-ros-base
```

instead of WSL's `execvpe(/bin/bash) failed` (S16).

`eject` deletes a folder only if it holds a `sparkle.meta` naming that same distro.

## Build

No crates: std only.

```
cargo test  --target x86_64-pc-windows-gnu
cargo build --release --target x86_64-pc-windows-gnu
```

Settings (env): `SPARKLE_HOME` (default `%USERPROFILE%\sparkle`), `SPARKLE_CRANE` (else `crane.exe` on PATH, else the spike's copy under `%LOCALAPPDATA%\sparkle-spike\tools`), `SPARKLE_BUSYBOX` (default `%USERPROFILE%\sparkle-bench\busybox`, copied, never moved), `SPARKLE_TOOL_DISTRO`. `crane` honours `HTTPS_PROXY`.

## End-to-end run

Run on 2026-10-31, one PC, **while three other sessions were using the same WSL VM and network** (one was downloading another image at the same time). All timings are single runs and provisional. `SPARKLE_HOME` pointed at a scratch folder outside the repo.

| Step | Result |
|---|---|
| `add clitest`, attempt 1 (crane via the HTTP proxy) | **failed** after ~10 min: `saving tarball ...: unexpected EOF`. `add` reported it and left nothing behind. |
| `add clitest`, attempt 2 (direct) | download **249.8 s** (297 MB tarball), flatten **8.0 s**, build **18.0 s** (mksquashfs 13.7 s), import **1.1 s**, total **276.9 s** |
| `add clitest2` (download cached) | flatten 7.2 s, build 14.5 s, import 1.0 s, total **22.8 s** |
| pack on disk after add | image.sqfs 336 MB + ext4.vhdx 113 MB = 449 MB (`ls`) |
| `enter clitest -- 'ros2 pkg list \| wc -l'` | **194**; 3.4 s from a stopped distro, 1.4 s when already running |
| `reset clitest` | 2.4 s (touch flag + `wsl -t sparkle-clitest`). A file written to `/usr/local/bin` before reset was gone after; `~/keep.txt` survived; boot log: `reset: upper wiped, dpkg db restored`; still 194 ROS packages |
| `enter` with `image.sqfs` renamed away | refused before launching WSL, exit 1, with the message above; `ls` marked the pack `(image file MISSING)` |
| `eject clitest2` | distro unregistered, folder deleted, `clitest` untouched |

**Against the pitch** ("working ROS 2 in about 15 s"): not met yet. With the image already downloaded, `add` took 22.8 s here (under load). The first `add` is dominated by the download (250 s at ~1.2 MB/s on this network). Most of the remaining time is mksquashfs (~14 s); flatten is 7–8 s, import ~1 s. Shipping prebuilt images, instead of building them on the user's PC, would remove both.

An `apt-get install` test of reset was a no-op (no package lists offline), so reset was checked with a file under `/usr` instead, not with a real package.

## Not done / limits

- **Needs a helper distro with mksquashfs.** `add` shells out to `SPARKLE_TOOL_DISTRO`; the design's self-contained builder (no helper distro) is not written.
- **Default home collides with the repo clone.** `%USERPROFILE%\sparkle` is also where this repo is cloned on the dev PC, so packs land in `sparkle\packs\` next to the source. The test run used `SPARKLE_HOME`. The default should probably move (e.g. `%USERPROFILE%\.sparkle`).
- **The image path is baked into the seed** (`/.sparkle/image` holds the `/mnt/c/...` path). Moving the pack folder breaks it; `enter` then reports the missing file.
- **No catalog, no OCI digest pinning, no progress bar**, no `--platform` other than linux/amd64, no image sharing between packs.
- If `add` fails before import, it deletes the pack folder it just made (the download cache is kept). If it fails after import, run `eject`.
- `reset` runs `wsl -t` on that one distro only. It never runs `wsl --shutdown`.
