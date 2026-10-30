# Sparkle v1 — design (Rust)

> This is the working design document, kept as written during the spikes (S1–S9). The
> benchmark spikes S10–S17 and their results are in [results.md](results.md); where they changed
> the design, [results.md § What changes in the design](results.md#what-changes-in-the-design)
> says so.

Status: design, not built. Written 2026-10-30 after spike 6 and a fact check of every external
claim below (sources at the end). The Haskell v0 stays as a reference; nothing of it is reused
except its spike findings, test cases and recipe format.

## 1. Goal

Ease of use, measured:

| Metric | Target | Today (v0 / plain WSL) |
|---|---|---|
| Zero → ROS talker running | **< 1 min** on a normal connection | 28.5 min (`sparkle add ros`) |
| Install Sparkle | one download, no admin, no config | build from source |
| Commands to learn | `add`, `<pack>`, `code`, `ls`, `eject` | 5 + env vars |
| Disk after eject | **exactly what it was before** | v0: same; plain WSL: never shrinks |
| GUI + GPU | works with no flags | needed env hacks |
| Bad network | fails fast, says which host, recovers itself | 548 s silent apt hang |
| Your code | never lost by `eject` or `update` without asking | not handled |

## 2. Decisions

### D1. One language, one binary: Rust
`sparkle.exe` is a single static Windows binary. There is no guest agent (see D2), so there is
no Linux build at all. Rust wins here on ecosystem, not speed: a maintained OCI registry client,
tar streaming, a custom HTTP connector, the `windows` crate, and installer tooling all exist
(versions in §10). Haskell would mean writing most of these.

### D2. Every pack is a real WSL distro, built from image layers
v0 ran packs as overlay/chroot sessions inside one base distro. Nothing outside Sparkle could
see them, and spike 6 found a corruption hazard: WSL idle shutdown clears `/run`, and the
next session silently mounted the wrong lower stack under the same upper layer.

v1: `sparkle add ros` creates WSL distro `sparkle-ros` from the `ros:jazzy-ros-base` image's layers.

- **Every tool just works:** VS Code (`code --remote wsl+sparkle-ros`), Windows Terminal
  profiles, `\\wsl$\sparkle-ros` in Explorer, systemd, docker/podman services, `wsl -d`.
- **Removed:** overlayfs, chroot, unshare, bind mounts, mount names, the guest script, the
  VHDX FFI and the stack-persistence bug class.
- **Eject is still "delete a file":** `wsl --unregister` deletes the distro's vhdx.
- **Cost:** each pack carries its own copy of Ubuntu (~30 MB compressed, ~80 MB on disk), and
  packs can't be stacked at runtime. Stacking happens when the pack is built instead (`extends`
  merges layer lists).

The original idea of a "tiny base with configs swapped on top" becomes "tiny independent packs,
swapped by add/eject". The user-visible promise is the same (no bloat, hot-swap, eject to zero).

### D3. Pull on Windows, stream straight into WSL
```
registry ──(parallel, verified)──▶ blob cache ──▶ flatten ──tar stream──▶ wsl --import sparkle-ros <dir> -
```
- **Registry client:** `oci-client` 0.18. It handles anonymous token auth, multi-platform index
  resolution and streaming blobs, and `pull_blob_stream_partial` gives resume. HTTP goes through
  our own connector (D6).
- **Blob cache:** `%LOCALAPPDATA%\sparkle\blobs\sha256\…`, content-addressed and shared between
  packs (ros-desktop reuses the ros-base layers). sha256 is checked while streaming. `sparkle gc`
  drops blobs no pack references, and `eject` offers it.
- **Flatten:** merges N layers into one tar, applying OCI whiteouts (`.wh.x` deletes `x`;
  `.wh..wh..opq` hides everything lower in that directory). Two passes over the compressed
  blobs (a few seconds for 283 MB):
  1. Index every layer's paths, whiteouts and opaque dirs.
  2. Emit entries bottom-up, skipping any entry that a higher layer replaces or deletes.
     Bottom-up keeps parents before children.

  Entry headers are copied as-is (uid/gid/mode/links). Xattrs such as file capabilities must
  be re-added as PAX records, because the `tar` crate does not carry them over. This is the
  riskiest code in the project, so it gets the most tests (§8).
- **Import:** `wsl --import <distro> <dir> - --version 2` reads stdin. Confirmed in WSL
  3.0.3's help. No temporary 1 GB tar.

### D4. A synthesized top layer makes it feel native
Sparkle appends one generated layer to the stream:

- `/etc/wsl.conf`:
  - default user = your Windows username
  - systemd off unless the recipe asks (faster start)
  - `generateResolvConf=true`
- `/etc/profile.d/sparkle.sh`:
  - `GALLIUM_DRIVER=d3d12`
  - `MESA_D3D12_DEFAULT_ADAPTER_NAME=<detected discrete GPU>`
  - `source /opt/ros/$ROS_DISTRO/setup.bash` when the image has ROS
- `/etc/wsl-distribution.conf`: shortcut icon and Windows Terminal profile (format from WSL
  2.4.4+). Whether `--import` applies all of it is only partly documented: it does create the
  Terminal profile (fixed in 2.6.0). That gets a spike (S2).
- `/etc/apt/apt.conf.d/90sparkle`:
  - `Acquire::http::Timeout "10"; Acquire::Retries "2";`
  - a dead mirror fails in seconds instead of 548 s
- `/etc/resolv.conf` removed (Microsoft's guidance).

After import, one root command creates the user (`useradd -m -G sudo`, passwordless sudo) and
sets permissions on the home directory.

### D5. A catalog, so nobody types image names

| `sparkle add …` | Image | Compressed | Measured pull |
|---|---|---|---|
| `ros` | `ros:jazzy-ros-base` | 282 MB | 4.7 s |
| `ros-desktop` (RViz) | `osrf/ros:jazzy-desktop` | 1203 MB | ~85 s est. at 14 MB/s |
| `ros-sim` (Gazebo) | `osrf/ros:jazzy-desktop-full` | 1356 MB | ~95 s est. |
| `ubuntu` | `ubuntu:24.04` | ~30 MB | — |
| `--image <ref>` | anything | | |

- `ros@humble` swaps the tag.
- The catalog ships inside the binary and refreshes from a small JSON on Cloudflare R2.
- Recipes become optional: `image` plus `steps` (shell run once after import) plus `extends`.

### D6. A network layer built for bad networks
Every slow or failed build so far was a network problem: one stalled GitHub IP, a dead
`packages.ros.org`, a 0.7 MB/s Ubuntu mirror.

- **Race the server's addresses.** Resolve every A/AAAA record (`hickory-resolver`) and start
  connections 250 ms apart; the first TLS handshake wins. hyper's built-in connector only tries
  addresses one after another and only races IPv4 vs IPv6, so this needs our own connector.
  This is the same trick a local racing proxy (Phaethon) uses for GitHub.
- **Stall watchdog.** 15 s without bytes drops that connection; Sparkle reconnects on another
  address and resumes with a Range request. The progress bar says which host stalled.
- **Mirrors.** For Docker Hub images, try `mirror.gcr.io` first: it is fast and doesn't count
  against Docker Hub limits, but it only holds what's popular. Fall back to
  `registry-1.docker.io`. Read the `ratelimit-*` headers at runtime: the docs say 100 per
  6 h per IP, while the live header said 100 per 1 h. If a pull would exceed the limit, say
  when it resets. HEAD requests on manifests don't count.
- **Proxy.** Honor `HTTPS_PROXY`, or set one with `sparkle config proxy http://127.0.0.1:8377`.
- **Our own images:** static OCI layout on Cloudflare R2 (measured 86 MB/s here).

### D7. The HertaSDK execution contract, ported to tokio
These rules keep concurrent `sparkle` runs from stepping on each other:

- Every operation declares its effect (idempotent / at-most-once). Retries happen only on
  transient failures.
- Weighted budgets cap the work:
  - 6 concurrent downloads
  - 1 import at a time (disk-heavy)
  - 1 apt run per pack
- Per-pack keyed serialization. Cancellation uses `CancellationToken`, and Ctrl-C drains cleanly.
- The cross-process lock is a named mutex (`CreateMutexW`, `Local\sparkle-<key>`). It replaces
  v0's lock files, and the OS releases it when a process crashes.
- Exit codes stay: 3 permanent, 4 transient, 5 throttled, 6 uncertain.
- v0's 32 Herta tests become the spec for this port.

### D8. Your work is never lost silently
- `eject` measures `/home/<you>` and `/root` against the image's skeleton. If you made anything
  there, it asks first:
  `ros has 1.2 GB of your files in ~/ws — export first? [Y/n]`
  Export goes to `%USERPROFILE%\sparkle-exports\ros-<date>.tar.gz`.
- `update ros`:
  1. builds `sparkle-ros-next` from the new image
  2. copies `/home` across with a tar pipe between the two distros
  3. replays the recipe steps
  4. swaps the names
  5. unregisters the old distro only after the new one passes a smoke test

  If any step fails, the old distro is untouched.
- A shared home disk across packs is v2. WSL mounts vanish on shutdown, and VS Code or
  Windows Terminal launching the distro directly would miss it.

### D9. Distribution
- `cargo-dist` 0.32 builds the MSI and PowerShell (`irm … | iex`) installers. Its "simple"
  hosting mode serves them from Cloudflare R2, with GitHub Releases as a fallback. GitHub
  downloads are unreliable on some networks (measured: TLS stalls to single CloudFront/GitHub IPs).
- winget is not something cargo-dist does: a CI step submits the manifest with `komac` or
  `wingetcreate`.
- **Signing:** Azure Artifact Signing ($9.99/mo) is only open to individuals in the US/Canada,
  so it is not an option everywhere. The fallback is a commercial code-signing certificate;
  cargo-dist supports SSL.com signing. Signing does not guarantee SmartScreen stays quiet:
  reputation builds over time.

### D10. The whole CLI

```
sparkle add ros               # pull + import + user setup, with progress
sparkle ros                   # shell in it  (= wsl -d sparkle-ros --cd ~)
sparkle ros -- colcon build   # run one command
sparkle code ros [path]       # VS Code attached to the pack
sparkle ls                    # packs, real size on disk, image, cache size
sparkle update ros            # D8
sparkle eject ros             # unregister → vhdx gone; asks if you have files
sparkle export ros [file]
sparkle doctor                # WSL version, virtualization, disk, GPU, WSLg, per-host network probe
sparkle gc                    # drop unreferenced cached layers
```

- No `init`: the first `add` checks WSL and sets everything up.
- Every error ends in a "try:" line, for example
  `packages.ros.org unreachable on all 3 addresses — try: sparkle config proxy …`.

## 3. Layout

```
sparkle/                  cargo workspace
  crates/sparkle          bin: CLI (clap), progress (indicatif), prompts, error rendering (miette)
  crates/sparkle-core     catalog, recipe (toml), state (json), Herta policy runtime
  crates/sparkle-oci      registry client wrapper, blob cache, flatten, racing connector, watchdog
  crates/sparkle-wsl      wsl.exe wrapper (WSL_UTF8=1, Wsl/... error-code parsing), named mutex
```
- **State:** `%LOCALAPPDATA%\sparkle\`
  - `state.json`: pack → distro, image ref, manifest digest, recipe hash, created
  - `blobs\`
  - `distros\<pack>\`: WSL install locations, short paths so the 260-char limit never bites
  - `logs\`
- `wsl.exe` output is read in UTF-8 via `WSL_UTF8=1` (verified on 3.0.3).

## 4. What a run looks like

```
> sparkle add ros
  ros → ros:jazzy-ros-base (amd64)        mirror.gcr.io
  layers  ████████████████████  283 MB  10/10 verified   4.9 s
  import  ████████████████████  41.7k files              ?? s   ← spike S1
  setup   user dev, GPU NVIDIA RTX 4060, ROS jazzy      1.2 s
  ready → sparkle ros   |   sparkle code ros
```

## 5. Spikes before building (each half a day or less)

| # | Question | Pass if |
|---|---|---|
| S1 | Flatten ros-base layers in Rust and stream into `wsl --import -` | imported in < 30 s; file count, owners, modes, hardlinks and `getcap` match the image |
| S2 | Does `--import` apply `wsl-distribution.conf` (Terminal profile, Start menu icon)? | profile and icon appear; if not, use `--install --from-file` with a temp `.wsl` |
| S3 | `sparkle code ros` → VS Code attaches; colcon build + talker inside | works with no prompts |
| S4 | GPU env from `/etc/profile.d` in a plain distro | glxinfo shows D3D12 NVIDIA |
| S5 | Is `osrf/ros:jazzy-desktop` on mirror.gcr.io? Pull speed of each source | numbers recorded; fallback works |

## 6. Milestones

1. **M1 Core loop:** `add` (catalog + `--image`), `<pack>`, `ls`, `eject`, `doctor` basics,
   progress, named-mutex locking.
2. **M2 Networks:** racing connector, stall watchdog, Range resume, mirror fallback, rate-limit
   headers, proxy config.
3. **M3 Safety:** eject file check and export, `update` with rollback, apt timeouts, `gc`.
4. **M4 Ship:** cargo-dist MSI and PowerShell installer on R2, winget manifest, signing,
   README with a 30-second GIF.
5. **M5 Your own packs:** `sparkle build recipe.toml` (image + steps → new OCI layer) and
   `sparkle push` to R2, built by CI so users only ever pull.

## 7. What carries over from v0
- Spike facts: GPU env, WSLg, the 260-char path limit, `WSL_E_DISK_ALREADY_MOUNTED` suffix
  matching, `--manage --compact`, never use sparse VHDs.
- Test cases: 32 Herta behaviors, 36 recipe/ledger cases, and the mount-name collision lesson
  (distros get a `sparkle-` prefix).
- Recipe TOML, gaining an `image` key.
- The Haskell source stays in `sparkle/` as a reference until v1 reaches M1, then gets archived.

## 8. Testing
- **Flatten:** golden tests. Synthetic layer tars cover whiteouts, opaque dirs, a hardlink
  whose target a higher layer replaces, long paths, xattrs and device nodes; expected merged
  tars are snapshots. Plus a property test: flatten(layers) equals what overlayfs shows for the
  same stack, checked in WSL in CI.
- **Policy:** port the Herta tests (budgets, keyed serialization, retry classes, cancellation).
- **Network:** a local test server with one address that never answers and one that stalls
  mid-body. The connector must finish within the watchdog bounds.
- **End to end** (needs WSL, runs nightly): add ros → colcon build → talker/listener → eject →
  check the vhdx is gone and disk usage is back to where it started.

## 9. Risks
| Risk | Mitigation |
|---|---|
| Flatten edge cases (hardlinks across layers, xattrs) | golden tests + overlayfs equivalence check; S1 |
| Docker Hub rate limits for heavy users | mirror.gcr.io first, cache layers, read headers, optional `sparkle login` (200/6 h) |
| Image publishers change tags or layouts | catalog pins digests; `update` is explicit |
| Defender slows big imports | measure in S1; no documented guidance, so no blind exclusions |
| SmartScreen on an unsigned exe | sign (D9); winget path |
| Each pack duplicates Ubuntu | ~80 MB per pack; acceptable for the simplicity gained |

## 10. Verified facts (2026-10-30)
- **WSL 3.0.3 (local `wsl --help`):**
  - `--import <Distro> <Dir> <File|-> [--version] [--vhd]`, and stdin works
  - `--import-in-place` exists
  - `--install --from-file` takes a path only
  - `--manage --compact` exists
- **`wsl-distribution.conf`:**
  - `[oobe] command/defaultUid/defaultName`, `[shortcut] enabled/icon`,
    `[windowsterminal] enabled/profileTemplate`; WSL 2.4.4+
  - learn.microsoft.com/windows/wsl/build-custom-distro
  - `--import` creates the Terminal profile: microsoft/WSL#13064, fixed 2.6.0
- VS Code: `code --remote wsl+<distro> <path>` works for any registered distro
  (code.visualstudio.com/docs/remote/wsl).
- `oci-client` 0.18.0 (2026-09-18, oras-project/rust-oci-client):
  - anonymous auth, index resolution
  - `pull_blob_stream`, `pull_blob_stream_partial`
- `tar` 0.4.46 (composefs/tar-rs):
  - header copy keeps uid/gid/mode/links
  - xattrs must be re-added as PAX
  - no whiteout logic
- hyper-util `HttpConnector`:
  - addresses are tried sequentially, with the timeout split between them
  - happy eyeballs only races IPv4 vs IPv6
  - reqwest `dns_resolver` is pluggable
- `hickory-resolver` 0.26.3; `windows` 0.62.2 (`CreateMutexW`, `Win32_Storage_Vhd`).
- `cargo-dist` 0.32.0:
  - msi, powershell and shell installers
  - simple hosting from 0.31 (any static URL)
  - no winget
  - SSL.com and Azure signing hooks
- **Docker Hub:**
  - docs: 100 pulls / 6 h per IPv4 or IPv6 /64 when anonymous; a live header showed
    `100;w=3600`
  - HEAD requests don't count
- `mirror.gcr.io` caches popular Docker Hub images on demand, with no guarantee. Local check:
  it served `library/ros:jazzy-ros-base`.
- Azure Artifact Signing: $9.99/mo Basic; public trust for individuals only in the US/CA.
- Measured here: Ubuntu mirror 0.7 MB/s, Docker Hub via CloudFront 14.4 MB/s, Cloudflare
  86 MB/s; `packages.ros.org` unreachable on all 3 IPs (also via a proxy); ros-base pull
  4.7 s + unpack 2.4 s.

## 11. Spike S1 results (2026-10-30)

S1 passed: the image becomes a working WSL distro in seconds.

**Import times.** Same local layers each run; two runs each, so ~±3 s of disk noise.

| Path | Time | Disk |
|---|---|---|
| `crane export - - < image.tar \| wsl --import … -` | 8.7 s / 13.2 s | 1,068 MB vhdx |
| our Rust merger → `wsl --import … -` | 6.8 s / 10.8 s (index 0.8 s) | 1,036 MB vhdx |

**Result in the distro:**
- First start 0.7 s, warm start 0.17 s.
- `nvidia-smi` sees the RTX 4060. WSLg works (`DISPLAY`, `WAYLAND_DISPLAY`, `/mnt/wslg`) with zero setup.
- colcon build + pub/sub pass.
- Fresh imports from crane and from our merger match on all 41,394 paths: type, mode, owner, size, link target and nlink. File contents match on 35,465 files. The only difference is `/var/cache/ldconfig/aux-cache`, which WSL writes at boot.

**Network.**
- `crane export` straight from Docker Hub failed twice: a TLS handshake timeout to one CloudFront address, retried three times. WSL then rejected the truncated stream (`WSL_E_NOT_A_LINUX_DISTRO`).
- Through a local proxy it worked but crawled (~45 min projected).
- This is direct evidence for D6: race the addresses, run a stall watchdog, and download fully before import. Never stream a network download straight into `wsl --import`.

**Merger edge cases.** 18 synthetic cases vs crane plus an OCI-spec model (harness:
`%LOCALAPPDATA%\sparkle-spike\s1\difftest\difftest.py`).
- Correct: whiteouts, opaque dirs, delete/re-create, dir↔file, long paths and link targets, xattrs incl.
  `security.capability`, PAX uid/gid, suid/sgid/sticky, devices, fifos.
- crane is wrong on a same-layer whiteout and we are right, so crane is a reference, not the oracle.
- Fixed during S1: copying the source header kept a stale ustar `prefix`, and paths just over 100
  chars came out doubled. Now we build fresh headers.

Must fix before M1 (confirmed by running):
1. Hardlinks: a link can be emitted before its target (extraction fails). A target that a
   higher layer replaces or deletes leaves the link dangling or pointing at new content. Fix:
   materialize such links as regular files with the target's original data, and only emit a
   link whose target's visible version is the same entry.
2. dir → file → dir leaks the first dir's children. Track the highest non-dir definition per path. (crane has this too.)
3. Root `./` entry is dropped (root mode/owner lost).
4. The broken-hardlink counter has false positives.

From the review (not reproduced yet):
- work in raw path bytes (real backslashes, non-UTF-8 names)
- sparse ('S') entries
- PAX size ≥ 8 GiB
- root-level opaque marker
- reject `..` / collapse `//` and `/./`
- skip PAX global headers and aufs `.wh..wh.plnk`
- old-style dirs (type '0' + trailing '/')
- carry PAX mtime precision
- `set_size(0)` on links

**Toolchain note.** This machine has no MSVC build tools, and Git Bash's `link` shadows `link.exe`. rustup
downloads at ~30 KB/s here. The GNU target (`x86_64-pc-windows-gnu`) works. Real builds belong in CI.

## 12. Zero-bloat layout (spike 7, 2026-10-30)

**Why VHDX bloat exists.** The ext4 VHDX grows on every write, and a normal (non-sparse) VHDX never gives space back. A pack's bloat comes from two sources:
1. The read-only bulk (/usr, /opt/ros), which is churned by apt upgrades.
2. Write-heavy scratch: build/, log/, ccache, pip cache, journald.

Sparkle removes both from the VHDX.

**Measured** (Ubuntu 24.04 + ROS jazzy pack, WSL 2 kernel, cold cache):

| /usr (881 MB raw) | size | full cold read | python cold import |
|---|---|---|---|
| ext4 inside VHDX | 881 MB, grows | 3.7 s | 0.1 s |
| squashfs lz4hc, file on NTFS | **329 MB, fixed** | **4.6 s** | **0.2 s** |
| squashfs xz, file on NTFS | 221 MB, fixed | 20.7 s | 0.5 s |

- Building the lz4hc image takes 8.8 s, and the xz image takes 30 s.
- /opt/ros is only 136 MB of the total.
- **Pitfall:** /usr/lib/wsl is the Windows driver store mounted in over 9p, about 7 GB. It must be excluded (`-e lib/wsl`). Leaving it in cost spike 7 its first 90 minutes.

**Design (D11):**
- **Base images.** Each pack's root tree is shipped as a read-only `<pack>.sqfs` (lz4hc) on NTFS under `%LOCALAPPDATA%\sparkle\images\`.
  - Images are content-addressed, so packs that share a base share the file.
  - They are written once and never grow.
- **Tiny writable VHDX** per pack, with a `--vhd-size` cap (default 8 GB), holding only:
  - an overlay upper layer for `/etc`, `/var/lib/dpkg` and user-installed packages
  - `/home`
- **Volatile paths on tmpfs**, and never on the disk:
  - `/tmp`, `/var/log/journal` (with `SystemMaxUse=16M`), `/var/cache/apt`
  - `~/.cache`, `ROS_LOG_DIR`, colcon `build/` and `log/` through a default `colcon.meta`/defaults.yaml
  - Exception: `sparkle keep build` opts a workspace's build directory back onto disk.
- **Reset instead of repair.**
  - `sparkle reset <pack>` drops the upper layer but keeps /home.
  - `sparkle upgrade <pack>` swaps in a new image file and deletes the old one when no pack references it.
  - Net effect: apt churn never piles up in the VHDX.
- **Automatic compaction.** When a pack stops, Sparkle runs `wsl --manage <d> --compact` (offline, about 6 s) once its upper layer has grown more than 1 GB since the last compact.
- **Sparse VHDX** stays an opt-in flag, because #10609 is still open.

**What's left to bloat:**
- The user's /home and the packages they apt-install on top of a pack. These are capped by the size limit and reclaimed by the auto-compact.
- Everything that ships with the pack is a fixed-size file on NTFS. Deleting a pack deletes exactly that file.

**Spikes S8/S9:** both pass, see §13.

## 13. Spikes S8 + S9 results (2026-10-30)

**Setup**
- **Image:** `pack.sqfs`, lz4hc, 352 MB, holding `/usr` and `/opt` of the ROS jazzy pack, with `-e /usr/lib/wsl`.
  - With more than one source dir, only the absolute exclude form works. `usr/lib/wsl` is silently ignored and drags in 3.8 GB of Windows drivers.
- **Seed:** a 25 MB tar (everything else, plus stubs). Imported, it is a **268 MB VHDX**, against 1.07 GB for the same pack on plain ext4 after compaction.
- **Source:** the scripts are in `%LOCALAPPDATA%\sparkle-spike\scripts\s8-*.sh` and `s9*.sh`. The live reference distro is `sparkle-s8b`.

### S8: booting a pack from a squashfs `/usr`
How WSL's `/init` boots (no systemd), and what it needs from the distro *before* any hook runs:
1. It creates `/sbin/mount.drvfs -> /init`. `/sbin` points to `usr/sbin`, so the seed must ship `usr/sbin`. Without it you get `E_UNEXPECTED` at CreateInstance.
2. It runs `/bin/mount -a` for fstab and `/sbin/ldconfig` for the GPU libs, synchronously.
3. It mounts drives by calling `/bin/mount -i -t 9p C:\ /mnt/c -o ...`, also synchronously. This is 9p, not drvfs.
4. It creates the session leader. Its mount namespace is snapshotted from init, and `/` is **not** a shared mount.
5. It runs `[boot] command`, **asynchronously**.

**Wrong approach (measured):** doing the mounting in `[boot] command`.
- The first `wsl` command fails with `execvpe(/bin/bash) ENOENT` on 10 of 10 cold boots.
- Mounts made after step 4 never reach the session, so a "wait for it" stub can't help.

**Working approach:** the seed's own `/usr` holds only stubs, and the image covers them once mounted.
- `/usr/bin/mount` is a busybox wrapper. It hands drvfs to `/init` and everything else to busybox.
- Once the drive holding the image is mounted, it mounts the image straight away, inside init's synchronous call:
  - loop-mount the squashfs
  - park `/usr/lib/wsl/{drivers,lib}` (rbind)
  - overlay `/usr` and `/opt` (upper and work dirs on the seed ext4)
  - restore the GPU mounts, recreate `mount.drvfs`, then run the real `ldconfig`
- `/usr/sbin/ldconfig` is a no-op stub until then.
- `[boot] command` stays as an idempotent fallback (it logs "already mounted").
- Static busybox v1.38 (1.7 MB) comes from `mirror.gcr.io/library/busybox:musl`. In v1 it becomes the static Rust `sparkle-init` (D11).

**Result:** 10 of 10 cold boots, and the first command each time runs the image's bash 5.2.21. The image mount takes 0.15–0.3 s.

| check on the squashfs-booted pack | result |
|---|---|
| OS, packages | Ubuntu 24.04.5, 602 dpkg packages, 194 ROS packages |
| ROS | `rclpy` node created |
| GPU | `nvidia-smi`: RTX 4060; `/usr/lib/wsl/lib` libcuda, 1037 driver dirs |
| interop, `/mnt/c` | `cmd.exe /c ver` 10.0.26300; C: mounted |
| cold start (`wsl --terminate`, then the first command, average of 5) | **622 ms** vs 489 ms for the same pack on plain ext4 (+130 ms) |
| image integrity | `dpkg -V`: 0 checksum mismatches. The 4,224 "missing" files are man/doc/locale that Docker strips, identical on ext4. |

### S9: apt and dpkg on the overlay
| action | upper-layer growth | notes |
|---|---|---|
| install a local .deb (5 MB) | +4.9 MB | exact |
| remove it again | +4 KB | no whiteouts |
| `apt install jq` (dpkg says 1,101 KB) | +1,044 KB | jq 1.7 works |
| `apt remove jq` | back to +20 KB | |
| `--reinstall sed`, an image package (340 KB) | +224 KB | copy-up of only the files rewritten |
| `apt install tree` | +96 KB | |
| remove an image package (`ros-jazzy-fastrtps`, 12 MB, 459 files) | **+56 KB** | 12 whiteouts; overlayfs hides whole dirs |
| `python -c 'import rclpy'` | +412 KB in the `opt` upper | 29 `__pycache__` .pyc files |
| `apt update` | +53 MB on the **seed disk** (`/var/lib/apt/lists`) | **the biggest bloat source** |

- **Reset** works. `touch /.sparkle/reset`, then a reboot: the boot code wipes the upper/work dirs and restores the seed's `/var/lib/dpkg` snapshot.
  - Afterwards the upper layer is 28 KB, the package count is back to 602, jq and tree are gone, and `dpkg --audit` and `dpkg -V` are clean.
- **Compaction:** non-sparse VHDXs reclaim fine. `s1-ours2` went from 7.31 GB to 1.07 GB in 7 s.
  - **A sparse VHDX cannot be compacted** (`ERROR_VIRTUAL_DISK_LIMITATION`). Sparse and compact are either/or, so D11 stays non-sparse plus auto-compact.

### Design changes from S8/S9
- **D11 boot:** Sparkle mounts the image from the stub `/bin/mount`, on the drive-mount call, never from `[boot] command`. The seed ships `usr/{bin/mount, sbin/ldconfig, sbin/, bin/sh}` and a static init helper.
- **Volatile paths** (adds to §12):
  - `/var/lib/apt/lists` goes on tmpfs. Sparkle's `add` wraps `apt-get update && install` in one session.
  - Set `PYTHONPYCACHEPREFIX=/run/user/pycache`, or pre-compile .pyc into the image at pack build (`python3 -m compileall`).
  - `/tmp` goes on tmpfs. In the spike it was on the seed disk and held about 10 MB of build leftovers.
- **Reset** restores the dpkg db along with the upper layer.
  - Open item: `/etc` changes from packages persist across a reset.
  - Next step: overlay `/etc` and `/var/lib/dpkg` too, so that a reset is a single "wipe the upper layer".
- **Image location:** the image must sit on a drive WSL automounts. If a user disables automount, Sparkle mounts that drive itself from the stub.
