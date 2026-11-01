//! sparkle: disposable, smaller WSL environments.
//!
//! A pack is a WSL distro `sparkle-<name>` whose /usr and /opt are a read-only squashfs image
//! on NTFS, mounted at boot by the stub in proto/stub. The pack is built by the same script the
//! benchmarks use (proto/build-fixtures.sh, embedded below, never edited here), run as root in a
//! helper distro that has mksquashfs.
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::Instant;

// The proto scripts, embedded so the binary is self-contained. Same bytes as the benchmarks.
const PROTO: &[(&str, &str)] = &[
    ("build-fixtures.sh", include_str!("../../proto/build-fixtures.sh")),
    ("common-setup.sh", include_str!("../../proto/common-setup.sh")),
    ("stub/init.sh", include_str!("../../proto/stub/init.sh")),
    ("stub/prewarm.sh", include_str!("../../proto/stub/prewarm.sh")),
    ("stub/mount", include_str!("../../proto/stub/mount")),
    ("stub/ldconfig", include_str!("../../proto/stub/ldconfig")),
    ("volatile/fstab", include_str!("../../proto/volatile/fstab")),
    ("volatile/profile.sh", include_str!("../../proto/volatile/profile.sh")),
];

const META: &str = "sparkle.meta";
const IMAGE: &str = "image.sqfs";
const VHDX: &str = "ext4.vhdx";

type Res<T> = Result<T, String>;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    match run(&args, &mut RealWsl) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("sparkle: {e}");
            ExitCode::from(1)
        }
    }
}

const USAGE: &str = "usage:
  sparkle add <name>                   download the prebuilt pack <name> (today: ros) and import it
  sparkle add <name> --image <ref>     build a pack on this PC from an OCI image (needs crane + helper distro)
  sparkle add <name> --build           build <name>'s default image on this PC instead of downloading
  sparkle enter <name> [-- cmd...]     open a shell in the pack (or run cmd)
  sparkle ls                           list packs with on-disk size and image
  sparkle reset <name>                 drop everything installed over the image (applies on next start)
  sparkle eject <name>                 unregister the distro and delete its files

env: SPARKLE_HOME (default %USERPROFILE%\\sparkle), SPARKLE_CRANE, SPARKLE_BUSYBOX,
     SPARKLE_TOOL_DISTRO (default sparkle-s1-ours2: any distro with mksquashfs >= 4.6)";

fn run(args: &[String], wsl: &mut dyn Wsl) -> Res<u8> {
    let cmd = args.first().map(String::as_str).unwrap_or("");
    let home = home_dir()?;
    match (cmd, args.len()) {
        ("add", 2..=4) => {
            let name = valid_name(&args[1])?;
            let image = match (args.get(2).map(String::as_str), args.len()) {
                (Some("--image"), 4) => args[3].clone(),
                (Some("--build"), 3) => default_image(name)?,
                (None, 2) => match prebuilt_url(name) {
                    Some(base) => return add_prebuilt(&home, name, &base, wsl).map(|_| 0),
                    None => default_image(name)?,
                },
                _ => return Err(format!("bad arguments to add\n{USAGE}")),
            };
            add(&home, name, &image, wsl).map(|_| 0)
        }
        ("enter", n) if n >= 2 => {
            let name = valid_name(&args[1])?;
            let rest = match args.get(2).map(String::as_str) {
                Some("--") => &args[3..],
                Some(o) => return Err(format!("unknown option {o}\n{USAGE}")),
                None => &args[2..],
            };
            enter(&home, name, rest, wsl)
        }
        ("ls", 1) => {
            print!("{}", ls(&home)?);
            Ok(0)
        }
        ("reset", 2) => reset(&home, valid_name(&args[1])?, wsl).map(|_| 0),
        ("eject", 2) => eject(&home, valid_name(&args[1])?, wsl).map(|_| 0),
        _ => {
            eprintln!("{USAGE}");
            Ok(2)
        }
    }
}

// ---------- paths and names ----------

fn home_dir() -> Res<PathBuf> {
    if let Ok(h) = env::var("SPARKLE_HOME") {
        return Ok(PathBuf::from(h));
    }
    let up = env::var("USERPROFILE").map_err(|_| "USERPROFILE not set; set SPARKLE_HOME")?;
    Ok(Path::new(&up).join("sparkle"))
}

fn pack_dir(home: &Path, name: &str) -> PathBuf {
    home.join("packs").join(name)
}

fn distro(name: &str) -> String {
    format!("sparkle-{name}")
}

/// Pack names become distro names and folder names: keep them boring.
fn valid_name(n: &str) -> Res<&str> {
    let ok = !n.is_empty()
        && n.len() <= 32
        && n.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !n.starts_with('-');
    if ok {
        Ok(n)
    } else {
        Err(format!("bad pack name {n:?}: use 1-32 of a-z, 0-9, '-'"))
    }
}

fn default_image(name: &str) -> Res<String> {
    match name {
        "ros" | "ros2" | "jazzy" => Ok("ros:jazzy-ros-base".into()),
        _ if name.starts_with("clitest") => Ok("ros:jazzy-ros-base".into()),
        _ => Err(format!("no default image for {name:?}: pass --image <ref>")),
    }
}

/// Where the prebuilt pack <name> is published (a GitHub release built by .github/workflows/pack.yml).
/// SPARKLE_PACK_URL overrides the base URL (a mirror, or file:///C:/... for testing).
fn prebuilt_url(name: &str) -> Option<String> {
    let tag = match name {
        "ros" | "ros2" | "jazzy" => "pack-ros",
        _ => return None,
    };
    Some(env::var("SPARKLE_PACK_URL")
        .unwrap_or_else(|_| format!("https://github.com/arahe-dev/sparkle/releases/download/{tag}")))
}

/// C:\Users\x\f -> /mnt/c/Users/x/f (WSL's default automount).
fn to_wsl(p: &Path) -> Res<String> {
    let s = p.to_string_lossy().replace('\\', "/");
    let b = s.as_bytes();
    if b.len() < 2 || b[1] != b':' || !b[0].is_ascii_alphabetic() {
        return Err(format!("{s} is not a drive path"));
    }
    Ok(format!("/mnt/{}{}", (b[0] as char).to_ascii_lowercase(), &s[2..]))
}

/// The cache file name for an image ref: ros:jazzy-ros-base -> ros_jazzy-ros-base.tar
fn cache_name(image: &str) -> String {
    let s: String = image
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '.' { c } else { '_' })
        .collect();
    format!("{s}.tar")
}

// ---------- pack metadata ----------

#[derive(Debug, PartialEq)]
struct Meta {
    image_ref: String,
    distro: String,
}

fn write_meta(dir: &Path, m: &Meta) -> Res<()> {
    let s = format!("image_ref={}\ndistro={}\n", m.image_ref, m.distro);
    fs::write(dir.join(META), s).map_err(|e| format!("write meta: {e}"))
}

fn read_meta(dir: &Path) -> Option<Meta> {
    let s = fs::read_to_string(dir.join(META)).ok()?;
    let get = |k: &str| {
        s.lines().find_map(|l| l.strip_prefix(k).and_then(|r| r.strip_prefix('=')).map(str::to_string))
    };
    Some(Meta { image_ref: get("image_ref")?, distro: get("distro")? })
}

// ---------- WSL boundary (mocked in tests) ----------

trait Wsl {
    /// Registered distro names.
    fn list(&mut self) -> Res<Vec<String>>;
    /// wsl.exe <args>, output inherited; returns the exit code.
    fn run(&mut self, args: &[&str]) -> Res<i32>;
    /// Run a shell script (sent on stdin, never on the command line) as root in a distro.
    fn script(&mut self, distro: &str, script: &str) -> Res<i32>;
    /// Pipe `crane export - -` of a tarball into `tar -x` inside the tool distro.
    fn flatten(&mut self, crane: &Path, tar: &Path, tool: &str, dest: &str) -> Res<()>;
}

struct RealWsl;

fn wsl_cmd() -> Command {
    let mut c = Command::new("wsl.exe");
    c.env("WSL_UTF8", "1");
    c
}

impl Wsl for RealWsl {
    fn list(&mut self) -> Res<Vec<String>> {
        let o = wsl_cmd().args(["-l", "-q"]).output().map_err(|e| format!("wsl.exe: {e}"))?;
        Ok(parse_list(&o.stdout))
    }
    fn run(&mut self, args: &[&str]) -> Res<i32> {
        let s = wsl_cmd().args(args).status().map_err(|e| format!("wsl.exe: {e}"))?;
        Ok(s.code().unwrap_or(1))
    }
    fn script(&mut self, distro: &str, script: &str) -> Res<i32> {
        let mut c = wsl_cmd()
            .args(["-d", distro, "-u", "root", "--cd", "/", "--", "sh", "-s"])
            .stdin(Stdio::piped())
            .spawn()
            .map_err(|e| format!("wsl.exe: {e}"))?;
        c.stdin.take().unwrap().write_all(script.as_bytes()).map_err(|e| e.to_string())?;
        Ok(c.wait().map_err(|e| e.to_string())?.code().unwrap_or(1))
    }
    fn flatten(&mut self, crane: &Path, tar: &Path, tool: &str, dest: &str) -> Res<()> {
        let mut ex = Command::new(crane)
            .args(["export", "-", "-"])
            .stdin(fs::File::open(tar).map_err(|e| format!("{}: {e}", tar.display()))?)
            .stdout(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{}: {e}", crane.display()))?;
        let out = ex.stdout.take().unwrap();
        let st = wsl_cmd()
            .args(["-d", tool, "-u", "root", "--", "tar", "-xpf", "-", "-C", dest])
            .args(["--numeric-owner", "--xattrs", "--xattrs-include=*"])
            .stdin(out)
            .status()
            .map_err(|e| format!("wsl.exe: {e}"))?;
        let ce = ex.wait().map_err(|e| e.to_string())?;
        if !ce.success() || !st.success() {
            return Err(format!("flatten failed (crane {ce}, tar {st})"));
        }
        Ok(())
    }
}

/// `wsl -l -q` prints UTF-16LE unless WSL_UTF8=1; accept both.
fn parse_list(raw: &[u8]) -> Vec<String> {
    let text = if raw.len() >= 2 && raw.iter().skip(1).step_by(2).take(8).all(|&b| b == 0) {
        let u: Vec<u16> = raw.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        String::from_utf16_lossy(&u)
    } else {
        String::from_utf8_lossy(raw).into_owned()
    };
    text.lines()
        .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}' || c == '\0'))
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

// ---------- tools ----------

fn find_crane() -> Res<PathBuf> {
    if let Ok(p) = env::var("SPARKLE_CRANE") {
        return Ok(p.into());
    }
    let mut cands = vec![];
    if let Ok(path) = env::var("PATH") {
        cands.extend(env::split_paths(&path).map(|d| d.join("crane.exe")));
    }
    if let Ok(l) = env::var("LOCALAPPDATA") {
        cands.push(Path::new(&l).join(r"sparkle-spike\tools\crane-v0.22.1\crane.exe"));
    }
    cands
        .into_iter()
        .find(|p| p.is_file())
        .ok_or_else(|| "crane.exe not found: put it on PATH or set SPARKLE_CRANE".into())
}

fn find_busybox() -> Res<PathBuf> {
    let p = match env::var("SPARKLE_BUSYBOX") {
        Ok(p) => PathBuf::from(p),
        Err(_) => Path::new(&env::var("USERPROFILE").unwrap_or_default()).join(r"sparkle-bench\busybox"),
    };
    if p.is_file() {
        Ok(p)
    } else {
        Err(format!("static busybox not found at {} (set SPARKLE_BUSYBOX)", p.display()))
    }
}

fn tool_distro() -> String {
    env::var("SPARKLE_TOOL_DISTRO").unwrap_or_else(|_| "sparkle-s1-ours2".into())
}

fn secs(t: Instant) -> f64 {
    t.elapsed().as_secs_f64()
}

// ---------- commands ----------

fn add(home: &Path, name: &str, image: &str, wsl: &mut dyn Wsl) -> Res<()> {
    let d = distro(name);
    let dir = pack_dir(home, name);
    if wsl.list()?.iter().any(|x| x.eq_ignore_ascii_case(&d)) {
        return Err(format!("{d} already exists (sparkle eject {name} first)"));
    }
    if dir.exists() {
        return Err(format!("{} already exists", dir.display()));
    }
    let crane = find_crane()?;
    let bb = find_busybox()?;
    let tool = tool_distro();
    let t_all = Instant::now();

    // 1. Download (cached per ref under SPARKLE_HOME\cache).
    let cache = home.join("cache");
    fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    let tar = cache.join(cache_name(image));
    let t = Instant::now();
    let dl = if tar.is_file() {
        println!("[1/4] image {image}: cached ({})", tar.display());
        None
    } else {
        println!("[1/4] pulling {image} (linux/amd64)");
        let part = tar.with_extension("tar.part");
        let st = Command::new(&crane)
            .args(["pull", "--platform", "linux/amd64", image])
            .arg(&part)
            .status()
            .map_err(|e| format!("crane: {e}"))?;
        if !st.success() {
            let _ = fs::remove_file(&part);
            return Err(format!("crane pull {image} failed ({st})"));
        }
        fs::rename(&part, &tar).map_err(|e| e.to_string())?;
        Some(secs(t))
    };

    // 2. Flatten into a tmpfs tree in the tool distro, then build image + seed with the
    //    benchmark script. The build files go in the pack folder so the tool distro sees them.
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let r = build_and_import(home, name, image, &dir, &crane, &bb, &tar, &tool, wsl);
    if r.is_err() {
        // The folder was made by this run and holds only build output; keep it only if the
        // distro got registered (then `eject` cleans up both).
        if wsl.list()?.iter().any(|x| x.eq_ignore_ascii_case(&d)) {
            eprintln!("sparkle: add failed after import; run `sparkle eject {name}` to clean up");
        } else {
            let _ = fs::remove_dir_all(&dir);
        }
    }
    let (t_flat, t_build, t_imp) = r?;
    let total = secs(t_all);
    let dl_s = dl.map(|s| format!("{s:.1} s")).unwrap_or_else(|| "cached".into());
    println!(
        "added {d}: download {dl_s}, flatten {t_flat:.1} s, build {t_build:.1} s, import {t_imp:.1} s, total {total:.1} s"
    );
    println!("enter it with: sparkle enter {name}");
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn build_and_import(
    _home: &Path, name: &str, image: &str, dir: &Path, crane: &Path, bb: &Path, tar: &Path,
    tool: &str, wsl: &mut dyn Wsl,
) -> Res<(f64, f64, f64)> {
    let build = dir.join(".build");
    for (rel, body) in PROTO {
        let p = build.join(rel);
        fs::create_dir_all(p.parent().unwrap()).map_err(|e| e.to_string())?;
        // LF only: busybox sh fails on CRLF (AGENTS.md).
        fs::write(&p, body.replace("\r\n", "\n")).map_err(|e| e.to_string())?;
    }
    fs::copy(bb, build.join("busybox")).map_err(|e| format!("copy busybox: {e}"))?;
    let (b, out) = (to_wsl(&build)?, to_wsl(dir)?);
    let tree = format!("/mnt/wsl/sparkle-build-{name}");

    let t = Instant::now();
    println!("[2/4] flattening layers in {tool}");
    let prep = format!(
        "set -e; mkdir -p {tree}; mountpoint -q {tree} || mount -t tmpfs -o size=8g tmpfs {tree}\n"
    );
    if wsl.script(tool, &prep)? != 0 {
        return Err(format!("could not make {tree} in {tool}"));
    }
    let res = wsl.flatten(crane, tar, tool, &tree);
    let t_flat = secs(t);

    let t = Instant::now();
    let built = res.and_then(|_| {
        println!("[3/4] building squashfs image + seed (proto/build-fixtures.sh)");
        let s = format!(
            "set -e\nsh {b}/build-fixtures.sh setup {tree} {out}\nsh {b}/build-fixtures.sh sparkle {tree} {out} {b}/busybox\n"
        );
        match wsl.script(tool, &s)? {
            0 => Ok(()),
            rc => Err(format!("pack build failed in {tool} (exit {rc})")),
        }
    });
    // Always free the tmpfs tree, even on failure.
    wsl.script(tool, &format!("umount {tree} 2>/dev/null; rmdir {tree} 2>/dev/null; true\n"))?;
    built?;
    let t_build = secs(t);

    let t = Instant::now();
    println!("[4/4] wsl --import {}", distro(name));
    let seed = dir.join("seed.tar");
    let (dir_s, seed_s) = (dir.to_string_lossy(), seed.to_string_lossy());
    let rc = wsl.run(&["--import", &distro(name), &dir_s, &seed_s, "--version", "2"])?;
    if rc != 0 {
        return Err(format!("wsl --import failed (exit {rc})"));
    }
    let t_imp = secs(t);
    write_meta(dir, &Meta { image_ref: image.into(), distro: distro(name) })?;
    // The seed is inside the distro now; the build files are not needed.
    let _ = fs::remove_file(&seed);
    let _ = fs::remove_file(dir.join("baseline-pkgs.txt"));
    let _ = fs::remove_dir_all(&build);
    Ok((t_flat, t_build, t_imp))
}

/// Download one file with curl.exe (ships with Windows; honours HTTPS_PROXY). A broken transfer
/// is retried by starting curl again on the same .part file, so each attempt resumes where the
/// last one stopped (curl's own --retry restarts the file). An HTTP error (exit 22) fails at once.
fn fetch(url: &str, dest: &Path) -> Res<()> {
    let part = dest.with_extension("part");
    let mut last = String::new();
    for attempt in 1..=6 {
        let st = Command::new("curl.exe")
            .args(curl_args(url, &part.to_string_lossy()))
            .status()
            .map_err(|e| format!("curl.exe: {e}"))?;
        if st.success() {
            return fs::rename(&part, dest).map_err(|e| e.to_string());
        }
        last = format!("{st}");
        if st.code() == Some(22) {
            break;
        }
        eprintln!("sparkle: download interrupted ({st}), resuming (attempt {attempt}/6)");
    }
    Err(format!("download failed: {url} ({last})"))
}

fn curl_args(url: &str, out: &str) -> Vec<String> {
    let mut a: Vec<String> = ["-fL", "--retry", "3", "-C", "-", "--progress-bar"].map(String::from).to_vec();
    a.extend(["-o".into(), out.into(), url.into()]);
    a
}

/// SHA-256 of a file, via certutil (ships with Windows; std has no hashing).
fn sha256(p: &Path) -> Res<String> {
    let o = Command::new("certutil").arg("-hashfile").arg(p).arg("SHA256").output()
        .map_err(|e| format!("certutil: {e}"))?;
    parse_certutil(&String::from_utf8_lossy(&o.stdout))
        .ok_or_else(|| format!("certutil gave no SHA256 for {}", p.display()))
}

fn parse_certutil(out: &str) -> Option<String> {
    out.lines()
        .map(|l| l.replace(' ', "").trim().to_ascii_lowercase())
        .find(|l| l.len() == 64 && l.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// `sha256sum` output: "<hex>  <file>" per line.
fn parse_sums(s: &str) -> Vec<(String, String)> {
    s.lines()
        .filter_map(|l| {
            let (h, f) = l.split_once(' ')?;
            Some((h.to_ascii_lowercase(), f.trim_start_matches([' ', '*']).trim().to_string()))
        })
        .collect()
}

fn add_prebuilt(home: &Path, name: &str, base: &str, wsl: &mut dyn Wsl) -> Res<()> {
    let d = distro(name);
    let dir = pack_dir(home, name);
    if wsl.list()?.iter().any(|x| x.eq_ignore_ascii_case(&d)) {
        return Err(format!("{d} already exists (sparkle eject {name} first)"));
    }
    if dir.exists() {
        return Err(format!("{} already exists", dir.display()));
    }
    let img = to_wsl(&dir.join(IMAGE))?; // before downloading: the pack must be on a drive path
    let t_all = Instant::now();

    let t = Instant::now();
    let (release, stage) = download(home, name, base)?;
    let t_dl = secs(t);

    // Only now make the pack folder; the image moves in from the staging folder (same drive).
    fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    for f in [IMAGE, "source.txt", "SHA256SUMS"] {
        let r = if f == IMAGE { fs::rename(stage.join(f), dir.join(f)) } else { fs::copy(stage.join(f), dir.join(f)).map(|_| ()) };
        if let Err(e) = r {
            let _ = fs::rename(dir.join(IMAGE), stage.join(IMAGE));
            let _ = fs::remove_dir_all(&dir);
            return Err(format!("moving {f} into {}: {e}", dir.display()));
        }
    }
    let t = Instant::now();
    println!("[2/3] wsl --import {d}");
    let (dir_s, seed_s) = (dir.to_string_lossy().to_string(), stage.join("seed.tar").to_string_lossy().to_string());
    let rc = wsl.run(&["--import", &d, &dir_s, &seed_s, "--version", "2"])?;
    if rc != 0 {
        let _ = fs::rename(dir.join(IMAGE), stage.join(IMAGE));
        let _ = fs::remove_dir_all(&dir);
        return Err(format!("wsl --import failed (exit {rc})"));
    }
    // Registered: write the meta now, so `eject` can clean up whatever happens next.
    let source = fs::read_to_string(dir.join("source.txt")).unwrap_or_default();
    write_meta(&dir, &Meta { image_ref: source.lines().next().unwrap_or(&release).trim().to_string(), distro: d.clone() })?;
    // The seed names the image by the path it was built at; point it at this PC's copy. Nothing
    // under /usr exists until the image mounts, so this uses the pack's own busybox. The path is
    // an argument, not part of the script, so quotes and spaces in it are harmless.
    println!("[3/3] pointing the pack at {}", dir.join(IMAGE).display());
    let rc = wsl.run(&["-d", &d, "-u", "root", "--cd", "/", "--exec", "/.sparkle/bin/busybox", "sh", "-c",
        "echo \"$1\" > /.sparkle/image", "sh", &img])?;
    wsl.run(&["-t", &d])?;
    if rc != 0 {
        return Err(format!("could not set the image path in {d} (exit {rc}); run `sparkle eject {name}` and try again"));
    }
    let _ = fs::remove_file(stage.join("seed.tar"));
    println!("added {d} from {release}: download {t_dl:.1} s, import {:.1} s, total {:.1} s", secs(t), secs(t_all));
    println!("enter it with: sparkle enter {name}");
    Ok(())
}

/// Fetch and verify a release's files into SPARKLE_HOME\cache\pack-<name>\<release>\. The folder
/// survives a failed or interrupted run, so the next `add` resumes, and files that already match
/// SHA256SUMS are not fetched again. Returns (release, folder).
fn download(home: &Path, name: &str, base: &str) -> Res<(String, PathBuf)> {
    // base/LATEST names the immutable release that holds the files (pack.yml makes one per build
    // and only then moves LATEST). Without it (a mirror, file:///), the files are at base itself.
    let cache = home.join("cache").join(format!("pack-{name}"));
    fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    let latest = cache.join("LATEST");
    let _ = fs::remove_file(&latest);
    let _ = fs::remove_file(latest.with_extension("part"));
    println!("[1/3] downloading pack {name} from {base}");
    let (release, url) = match fetch(&format!("{base}/LATEST"), &latest) {
        Ok(()) => {
            let tag = fs::read_to_string(&latest).unwrap_or_default().trim().to_string();
            if tag.is_empty() || !tag.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.') {
                return Err(format!("{base}/LATEST does not name a release: {tag:?}"));
            }
            let root = base.rsplit_once('/').map(|(r, _)| r).unwrap_or(base);
            (tag.clone(), format!("{root}/{tag}"))
        }
        Err(_) => ("direct".to_string(), base.to_string()),
    };
    let stage = cache.join(&release);
    fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
    let sums_path = stage.join("SHA256SUMS");
    let _ = fs::remove_file(sums_path.with_extension("part"));
    fetch(&format!("{url}/SHA256SUMS"), &sums_path)
        .map_err(|e| format!("{e}\nNo prebuilt pack reachable; to build it on this PC: sparkle add {name} --build"))?;
    let sums = parse_sums(&fs::read_to_string(&sums_path).map_err(|e| e.to_string())?);
    for f in ["source.txt", "seed.tar", IMAGE] {
        let want = sums.iter().find(|(_, n)| n == f).map(|(h, _)| h.clone())
            .ok_or_else(|| format!("SHA256SUMS has no entry for {f}"))?;
        let p = stage.join(f);
        if p.is_file() && sha256(&p)? == want {
            continue; // from an earlier run of this release
        }
        fetch(&format!("{url}/{f}"), &p)?;
        let got = sha256(&p)?;
        if got != want {
            let _ = fs::remove_file(&p);
            return Err(format!("{f}: checksum mismatch (expected {want}, got {got}); run add again to re-download it"));
        }
    }
    Ok((release, stage))
}

/// Why a pack can't start, or None if it can.
fn preflight(home: &Path, name: &str, registered: &[String]) -> Option<String> {
    let dir = pack_dir(home, name);
    let d = distro(name);
    let Some(m) = read_meta(&dir) else {
        return Some(format!("no pack named {name:?} (no {}). Try: sparkle ls", dir.join(META).display()));
    };
    let img = dir.join(IMAGE);
    if !img.is_file() {
        return Some(format!(
            "the image for pack {name:?} is missing: {}\n\
             The pack's /usr and /opt live in that file, so {d} cannot start without it.\n\
             Fix: restore the file to that path, or rebuild the pack:\n  \
             sparkle eject {name}\n  sparkle add {name} --image {}",
            img.display(),
            m.image_ref
        ));
    }
    if !registered.iter().any(|x| x.eq_ignore_ascii_case(&d)) {
        return Some(format!("{d} is not registered with WSL. Rebuild: sparkle eject {name} && sparkle add {name}"));
    }
    None
}

fn enter(home: &Path, name: &str, cmd: &[String], wsl: &mut dyn Wsl) -> Res<u8> {
    if let Some(why) = preflight(home, name, &wsl.list()?) {
        return Err(why);
    }
    let d = distro(name);
    let mut args: Vec<&str> = vec!["-d", &d, "--cd", "~"];
    if !cmd.is_empty() {
        // A login shell so /etc/profile.d (ROS setup) applies, as in an interactive shell.
        args.extend(["--", "bash", "-lc"]);
        let joined = cmd.join(" ");
        return wsl.run(&[&args[..], &[joined.as_str()]].concat()).map(|c| c as u8);
    }
    wsl.run(&args).map(|c| c as u8)
}

fn dir_size(p: &Path) -> u64 {
    [IMAGE, VHDX].iter().filter_map(|f| fs::metadata(p.join(f)).ok()).map(|m| m.len()).sum()
}

fn ls(home: &Path) -> Res<String> {
    let mut rows = vec![];
    if let Ok(rd) = fs::read_dir(home.join("packs")) {
        for e in rd.flatten() {
            if let Some(m) = read_meta(&e.path()) {
                let name = e.file_name().to_string_lossy().into_owned();
                let img_ok = e.path().join(IMAGE).is_file();
                rows.push((name, dir_size(&e.path()), m.image_ref, img_ok));
            }
        }
    }
    rows.sort();
    let mut s = format!("{:<20} {:>10}  {}\n", "PACK", "ON DISK", "IMAGE");
    for (n, b, r, ok) in rows {
        let warn = if ok { "" } else { "  (image file MISSING)" };
        s += &format!("{:<20} {:>7.0} MB  {}{}\n", n, b as f64 / 1e6, r, warn);
    }
    Ok(s)
}

fn reset(home: &Path, name: &str, wsl: &mut dyn Wsl) -> Res<()> {
    if let Some(why) = preflight(home, name, &wsl.list()?) {
        return Err(why);
    }
    let d = distro(name);
    let rc = wsl.run(&["-d", &d, "-u", "root", "--", "/.sparkle/bin/busybox", "touch", "/.sparkle/reset"])?;
    if rc != 0 {
        return Err(format!("could not mark {d} for reset (exit {rc})"));
    }
    // Terminate this distro only; the reset happens when it next starts.
    wsl.run(&["-t", &d])?;
    println!("{d} will start clean next time (packages installed over the image are dropped; /home is kept)");
    Ok(())
}

fn eject(home: &Path, name: &str, wsl: &mut dyn Wsl) -> Res<()> {
    let d = distro(name);
    let dir = pack_dir(home, name);
    // Only delete folders sparkle made: they have a meta file naming this distro.
    let meta = read_meta(&dir);
    if let Some(m) = &meta {
        if m.distro != d {
            return Err(format!("{} belongs to {}, not {d}; not touching it", dir.display(), m.distro));
        }
    }
    let registered = wsl.list()?.iter().any(|x| x.eq_ignore_ascii_case(&d));
    if meta.is_none() && !registered {
        return Err(format!("no pack named {name:?}"));
    }
    if registered {
        let rc = wsl.run(&["--unregister", &d])?;
        if rc != 0 {
            return Err(format!("wsl --unregister {d} failed (exit {rc}); files kept"));
        }
    }
    if meta.is_some() {
        fs::remove_dir_all(&dir).map_err(|e| format!("delete {}: {e}", dir.display()))?;
    } else if dir.exists() {
        eprintln!("left {} in place: it has no {META}, so sparkle did not make it", dir.display());
    }
    println!("ejected {d}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Mock {
        distros: Vec<String>,
        calls: Vec<String>,
    }
    impl Wsl for Mock {
        fn list(&mut self) -> Res<Vec<String>> {
            Ok(self.distros.clone())
        }
        fn run(&mut self, args: &[&str]) -> Res<i32> {
            self.calls.push(args.join(" "));
            if args[0] == "--unregister" {
                self.distros.retain(|d| d != args[1]);
            }
            Ok(0)
        }
        fn script(&mut self, d: &str, _: &str) -> Res<i32> {
            self.calls.push(format!("script {d}"));
            Ok(0)
        }
        fn flatten(&mut self, _: &Path, _: &Path, _: &str, _: &str) -> Res<()> {
            Ok(())
        }
    }

    fn tmp(tag: &str) -> PathBuf {
        let p = env::temp_dir().join(format!("sparkle-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn fake_pack(home: &Path, name: &str, with_image: bool) -> PathBuf {
        let dir = pack_dir(home, name);
        fs::create_dir_all(&dir).unwrap();
        write_meta(&dir, &Meta { image_ref: "ros:jazzy-ros-base".into(), distro: distro(name) }).unwrap();
        fs::write(dir.join(VHDX), vec![0u8; 3_000_000]).unwrap();
        if with_image {
            fs::write(dir.join(IMAGE), vec![0u8; 2_000_000]).unwrap();
        }
        dir
    }

    #[test]
    fn names() {
        assert!(valid_name("ros").is_ok());
        assert!(valid_name("clitest-2").is_ok());
        for bad in ["", "Ros", "a b", "../x", "-x", "a_b", &"x".repeat(33)] {
            assert!(valid_name(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn wsl_paths() {
        assert_eq!(to_wsl(Path::new(r"C:\Users\x\sparkle\packs\ros")).unwrap(), "/mnt/c/Users/x/sparkle/packs/ros");
        assert_eq!(to_wsl(Path::new(r"D:\a")).unwrap(), "/mnt/d/a");
        assert!(to_wsl(Path::new(r"\\wsl$\x")).is_err());
    }

    #[test]
    fn cache_names() {
        assert_eq!(cache_name("ros:jazzy-ros-base"), "ros_jazzy-ros-base.tar");
        assert_eq!(cache_name("ghcr.io/a/b@sha256:ab"), "ghcr.io_a_b_sha256_ab.tar");
    }

    #[test]
    fn list_parsing_utf16_and_utf8() {
        let u16: Vec<u8> = "Ubuntu\r\nsparkle-ros\r\n".encode_utf16().flat_map(|c| c.to_le_bytes()).collect();
        assert_eq!(parse_list(&u16), vec!["Ubuntu", "sparkle-ros"]);
        assert_eq!(parse_list(b"Ubuntu\nsparkle-ros\n"), vec!["Ubuntu", "sparkle-ros"]);
    }

    #[test]
    fn meta_roundtrip() {
        let h = tmp("meta");
        let m = Meta { image_ref: "ros:jazzy-ros-base".into(), distro: "sparkle-ros".into() };
        write_meta(&h, &m).unwrap();
        assert_eq!(read_meta(&h), Some(m));
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn enter_refuses_missing_image_with_clear_message() {
        let h = tmp("enter");
        fake_pack(&h, "ros", false);
        let mut w = Mock { distros: vec!["sparkle-ros".into()], ..Default::default() };
        let e = enter(&h, "ros", &[], &mut w).unwrap_err();
        assert!(e.contains("image for pack \"ros\" is missing"), "{e}");
        assert!(e.contains(IMAGE) && e.contains("sparkle add ros --image ros:jazzy-ros-base"), "{e}");
        assert!(w.calls.is_empty(), "must not launch wsl");
        fs::write(pack_dir(&h, "ros").join(IMAGE), b"x").unwrap();
        enter(&h, "ros", &[], &mut w).unwrap();
        assert_eq!(w.calls, vec!["-d sparkle-ros --cd ~"]);
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn enter_runs_command_in_login_shell() {
        let h = tmp("enter2");
        fake_pack(&h, "ros", true);
        let mut w = Mock { distros: vec!["sparkle-ros".into()], ..Default::default() };
        enter(&h, "ros", &["ros2 pkg list".into(), "| wc -l".into()], &mut w).unwrap();
        assert_eq!(w.calls, vec!["-d sparkle-ros --cd ~ -- bash -lc ros2 pkg list | wc -l"]);
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn ls_shows_size_and_ref() {
        let h = tmp("ls");
        fake_pack(&h, "ros", true);
        fake_pack(&h, "gone", false);
        let out = ls(&h).unwrap();
        assert!(out.contains("ros") && out.contains("5 MB") && out.contains("ros:jazzy-ros-base"), "{out}");
        assert!(out.lines().any(|l| l.starts_with("gone") && l.contains("MISSING")), "{out}");
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn reset_touches_flag_then_terminates_only_that_distro() {
        let h = tmp("reset");
        fake_pack(&h, "ros", true);
        let mut w = Mock { distros: vec!["sparkle-ros".into(), "Ubuntu".into()], ..Default::default() };
        reset(&h, "ros", &mut w).unwrap();
        assert_eq!(
            w.calls,
            vec!["-d sparkle-ros -u root -- /.sparkle/bin/busybox touch /.sparkle/reset", "-t sparkle-ros"]
        );
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn eject_unregisters_and_deletes_only_its_folder() {
        let h = tmp("eject");
        let dir = fake_pack(&h, "ros", true);
        let other = fake_pack(&h, "keep", true);
        let mut w = Mock { distros: vec!["sparkle-ros".into(), "sparkle-keep".into()], ..Default::default() };
        eject(&h, "ros", &mut w).unwrap();
        assert_eq!(w.calls, vec!["--unregister sparkle-ros"]);
        assert!(!dir.exists() && other.exists());
        assert_eq!(w.distros, vec!["sparkle-keep"]);
        assert!(eject(&h, "ros", &mut w).is_err(), "second eject: nothing left");
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn eject_keeps_folder_without_meta() {
        let h = tmp("eject2");
        let dir = pack_dir(&h, "ros");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("precious.txt"), b"x").unwrap();
        let mut w = Mock { distros: vec!["sparkle-ros".into()], ..Default::default() };
        eject(&h, "ros", &mut w).unwrap();
        assert!(dir.join("precious.txt").exists());
        // A meta naming another distro is refused outright.
        write_meta(&dir, &Meta { image_ref: "x".into(), distro: "sparkle-other".into() }).unwrap();
        assert!(eject(&h, "ros", &mut w).is_err());
        assert!(w.calls == vec!["--unregister sparkle-ros"]);
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn add_refuses_existing_distro() {
        let h = tmp("add");
        let mut w = Mock { distros: vec!["sparkle-ros".into()], ..Default::default() };
        assert!(add(&h, "ros", "ros:jazzy-ros-base", &mut w).unwrap_err().contains("already exists"));
        fs::remove_dir_all(h).unwrap();
    }

    #[test]
    fn curl_output_follows_dash_o() {
        let a = curl_args("https://x/f", "C:/p/f.part");
        let i = a.iter().position(|x| x == "-o").unwrap();
        assert_eq!(a[i + 1], "C:/p/f.part");
        assert_eq!(a.last().unwrap(), "https://x/f");
        assert!(a.contains(&"-C".to_string()) && !a.contains(&"--retry-all-errors".to_string()));
    }

    #[test]
    fn parses_checksums() {
        let c = "SHA256 hash of x:\r\n9f 86 d0 81 88 4c 7d 65 9a 2f ea a0 c5 5a d0 15 a3 bf 4f 1b 2b 0b 82 2c d1 5d 6c 15 b0 f0 0a 08\r\nCertUtil: -hashfile command completed successfully.\r\n";
        assert_eq!(parse_certutil(c).unwrap(), "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08");
        let s = parse_sums("AB12  image.sqfs\ncd34 *seed.tar\n");
        assert_eq!(s, vec![("ab12".to_string(), "image.sqfs".to_string()), ("cd34".to_string(), "seed.tar".to_string())]);
        assert!(prebuilt_url("misc").is_none());
    }

    #[test]
    fn embeds_every_file_build_fixtures_reads() {
        let (_, script) = PROTO[0];
        // Only the plain `$P/path` form is recognised; fail on any other spelling of it.
        assert!(!script.contains("${P}") && !script.contains("\"$P\"/"), "use the $P/path form");
        let mut n = 0;
        for word in script.split(|c: char| c.is_whitespace() || c == '"') {
            if let Some(rel) = word.strip_prefix("$P/") {
                n += 1;
                assert!(PROTO.iter().any(|(n, _)| *n == rel), "build-fixtures.sh reads {rel}, not embedded");
            }
        }
        assert!(n >= 7, "found only {n} $P/ reads; the parser no longer matches the script");
    }

    #[test]
    fn embedded_scripts_are_lf() {
        for (n, b) in PROTO {
            assert!(!b.contains('\r') || n.is_empty(), "{n} has CR (written LF anyway)");
        }
    }
}
