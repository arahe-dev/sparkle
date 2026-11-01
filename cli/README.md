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

`bash bench/cli-e2e.sh <sparkle.exe>` on 2026-11-01, on a quiet machine (nothing else using WSL; see [methodology](../docs/methodology.md#the-quiet-re-run-2026-11-01)). It times the release binary from the host: one `add` with the download, then 3 cached `add`s (`eject` between them), 3 cold `enter`s and 3 `reset`s. Raw rows: [bench/results/raw/cli.jsonl](../bench/results/raw/cli.jsonl).

| Step | Result |
|---|---|
| `add e2e --image ros:jazzy-ros-base`, first (with download) | download **8.4 s** (direct, no proxy), flatten 6.0 s, build 13.0 s, import 0.8 s, total **28.3 s** |
| `add`, image cached (n = 3) | flatten 5.9 s, build 14.7–15.0 s, import 0.7 s, total **21.4–21.7 s** |
| pack on disk after `add` | image.sqfs 336 MB + ext4.vhdx 113 MB = 449 MB |
| `enter e2e -- 'ros2 pkg list \| wc -l'` from a stopped distro (n = 3) | **194** packages every time; 2.35–2.84 s |
| `enter e2e -- true`, already running (n = 3) | 0.82–0.92 s |
| `reset e2e` (n = 3) | 0.34–0.36 s for the command (flag + `wsl -t`); the next `enter` took 2.34–2.61 s and found a file written to `/usr/local/bin` before the reset gone, 3/3 |
| `enter` with `image.sqfs` renamed away | refused before launching WSL, exit 1: `sparkle: the image for pack e2e is missing: <home>/sparkle-cli-e2e/packs/e2e/image.sqfs` |
| `eject e2e` | distro unregistered, folder deleted |

**Against the pitch** ("working ROS 2 in about 15 s"): not met yet. With the image cached, `add` takes 21–22 s; most of it is building the squashfs image on the user's PC (~15 s), then flattening the layers (~6 s). Shipping prebuilt images, built in CI and downloaded, would remove both. The download itself was fast this time (8.4 s for 297 MB). On 2026-10-31 the same download took 250 s, and once failed with `unexpected EOF` through the HTTP proxy, so the network, not the tool, dominates a first `add`.

The first CLI run (2026-10-31, under load from three other sessions) gave 22.8 s for a cached `add`, 3.4 s for a cold `enter` and 2.4 s for `reset`. It is in git history at commit 83743a4.

## Not done / limits

- **Needs a helper distro with mksquashfs.** `add` shells out to `SPARKLE_TOOL_DISTRO`; the design's self-contained builder (no helper distro) is not written.
- **Default home collides with the repo clone.** `%USERPROFILE%\sparkle` is also where this repo is cloned on the dev PC, so packs land in `sparkle\packs\` next to the source. The test run used `SPARKLE_HOME`. The default should probably move (e.g. `%USERPROFILE%\.sparkle`).
- **The image path is baked into the seed** (`/.sparkle/image` holds the `/mnt/c/...` path). Moving the pack folder breaks it; `enter` then reports the missing file.
- **No catalog, no OCI digest pinning, no progress bar**, no `--platform` other than linux/amd64, no image sharing between packs.
- **Packs use the S10–S17 layout:** squashfs image, upper layer on the seed disk. S18's reclaimable upper file and S19's erofs image are measured but not in the CLI yet (reset would have to create the sparse upper file from the host; erofs needs the kernel module loaded at boot).
- If `add` fails before import, it deletes the pack folder it just made (the download cache is kept). If it fails after import, run `eject`.
- `reset` runs `wsl -t` on that one distro only. It never runs `wsl --shutdown`.
