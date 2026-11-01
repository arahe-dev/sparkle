# sparkle CLI (v0.1, first working cut)

```
sparkle add <name>                   download the prebuilt pack <name> (today: ros) and import it
sparkle add <name> --image <ref>     build a pack on this PC from an OCI image (needs crane + helper distro)
sparkle add <name> --build           build <name>'s default image on this PC instead of downloading
sparkle enter <name> [-- cmd...]     open a shell in the pack (or run cmd in a login bash)
sparkle ls                           list packs with on-disk size (image + vhdx) and image ref
sparkle reset <name>                 drop everything installed over the image (applies on next start)
sparkle eject <name>                 wsl --unregister the distro, then delete its pack folder
```

`add ros` downloads a prebuilt pack of `ros:jazzy-ros-base` (linux/amd64). Other names need `--image`.

## Prebuilt packs (`sparkle add ros`)

CI builds the pack once and publishes it; the user's PC only downloads and imports it. No crane, no helper distro, no `mksquashfs`.

1. **Built by** [.github/workflows/pack.yml](../.github/workflows/pack.yml) (run by hand: `gh workflow run pack.yml -f name=ros -f image=ros:jazzy-ros-base`) on `ubuntu-24.04`. It pins the image digest, flattens it, runs the same `proto/build-fixtures.sh` as the benchmarks and the local build (with Ubuntu's `busybox-static`), and uploads `image.sqfs`, `seed.tar`, `source.txt` (image ref + digest) and `SHA256SUMS` to the release `pack-<name>`.
2. **`add`** downloads the four files with `curl.exe` (resumes, retries; honours `HTTPS_PROXY`), checks each against `SHA256SUMS` with `certutil`, then runs `wsl --import`.
3. **Re-point:** the seed names the image by the path it was built at, so `add` writes this PC's path into `/.sparkle/image` with the pack's own busybox, then `wsl -t`. The next start mounts the image.
4. The pack folder keeps `image.sqfs`, `ext4.vhdx`, `SHA256SUMS`, `source.txt` and `sparkle.meta` (its `image_ref` is the pinned digest).

`SPARKLE_PACK_URL` overrides the download base (a mirror, or `file:///C:/...`). `SHA256SUMS` comes from the same release, so it catches corrupt downloads, not a tampered release.

Tested on 2026-11-01 against a pack built locally exactly as the workflow does (same digest, same script, the benchmark busybox), served from a `file:///` URL and moved away from its build path so the re-point step mattered:

| Step | Result |
|---|---|
| `add ros` (local "download", checksums, import, re-point) | **2.3 s** (download + verify 1.0 s, import + re-point 1.3 s). Over the network, add the download of 372 MB. |
| first `enter ros -- 'ros2 pkg list \| wc -l'` | 194 packages; `import rclpy` works; `/.sparkle/image` points at this PC's copy; 3.2 s |
| `reset ros`, then `enter` | a file written to `/usr/local/bin` before the reset is gone |
| `add ros` again | refused: `sparkle-ros already exists` |
| a wrong hash in `SHA256SUMS` | refused at the first file: `checksum mismatch`; no folder, no distro left |
| no release published (404) | fails in 0.5 s: `No prebuilt pack reachable; to build it on this PC: sparkle add ros --build` |

The workflow itself has not run yet, so the published pack (with Ubuntu's busybox) is untested.

## How `add --image` / `--build` works (local build)

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
| pack on disk after `add` | 449 MB (image + disk; the split was not recorded in this run) |
| `enter e2e -- 'ros2 pkg list \| wc -l'` from a stopped distro (n = 3) | **194** packages every time; 2.35–2.84 s |
| `enter e2e -- true`, already running (n = 3) | 0.82–0.92 s |
| `reset e2e` (n = 3) | 0.34–0.36 s for the command (flag + `wsl -t`); the next `enter` took 2.34–2.61 s and found a file written to `/usr/local/bin` before the reset gone, 3/3 |
| `enter` with `image.sqfs` renamed away | refused before launching WSL, exit 1: `sparkle: the image for pack e2e is missing: <home>/sparkle-cli-e2e/packs/e2e/image.sqfs` |
| `eject e2e` | distro unregistered, folder deleted |

**Against the pitch** ("working ROS 2 in about 15 s"): not met yet. With the image cached, `add` takes 21–22 s; most of it is building the squashfs image on the user's PC (~15 s), then flattening the layers (~6 s). Shipping prebuilt images, built in CI and downloaded, would remove both. The download itself was fast this time (8.4 s). On 2026-10-31 the same download took 250 s, and once failed with `unexpected EOF` through the HTTP proxy, so the network, not the tool, dominates a first `add`.

The first CLI run (2026-10-31, under load from three other sessions) gave 22.8 s for a cached `add`, 3.4 s for a cold `enter` and 2.4 s for `reset`. It is in git history at commit 83743a4.

## Not done / limits

- **Needs a helper distro with mksquashfs.** `add` shells out to `SPARKLE_TOOL_DISTRO`; the design's self-contained builder (no helper distro) is not written.
- **Default home collides with the repo clone.** `%USERPROFILE%\sparkle` is also where this repo is cloned on the dev PC, so packs land in `sparkle\packs\` next to the source. The test run used `SPARKLE_HOME`. The default should probably move (e.g. `%USERPROFILE%\.sparkle`).
- **The image path is baked into the seed** (`/.sparkle/image` holds the `/mnt/c/...` path). Moving the pack folder breaks it; `enter` then reports the missing file.
- **No catalog, no OCI digest pinning, no progress bar**, no `--platform` other than linux/amd64, no image sharing between packs.
- **Packs use the S10–S17 layout:** squashfs image, upper layer on the seed disk. S18's reclaimable upper file and S19's erofs image are measured but not in the CLI yet (reset would have to create the sparse upper file from the host; erofs needs the kernel module loaded at boot).
- If `add` fails before import, it deletes the pack folder it just made (the download cache is kept). If it fails after import, run `eject`.
- `reset` runs `wsl -t` on that one distro only. It never runs `wsl --shutdown`.
