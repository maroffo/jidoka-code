//! Optional Semgrep CE analysis of pinned head text with a bundled local rule.

use crate::{
    contracts::{Scan, Signal, Snapshot},
    source::safe_path,
};
use serde::Deserialize;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    env,
    ffi::{OsStr, OsString},
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{fs::PermissionsExt, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};
use tempfile::TempDir;

const RULE: &str = include_str!("../rules/python.yml");
const BATCH_SIZE: usize = 28;
const TARGET_BYTES: usize = 1_000_000;
const OUTPUT_BYTES: usize = 1_000_000;
const SIGNALS: usize = 100;
const SCAN_TIME: Duration = Duration::from_secs(20);
const DEFAULT_PATH: &str = "/usr/local/bin:/usr/bin:/bin";

fn applicable(path: &str) -> bool {
    matches!(
        Path::new(path).extension().and_then(|ext| ext.to_str()),
        Some("py" | "pyi")
    )
}

pub(crate) fn source_bytes(path: &str) -> Option<usize> {
    applicable(path).then_some(TARGET_BYTES)
}

fn targets<'a>(snapshot: &'a Snapshot, limits: &mut Vec<String>) -> Vec<(&'a str, &'a str)> {
    let mut counts = HashMap::new();
    for file in &snapshot.files {
        *counts.entry(file.path.as_str()).or_insert(0) += 1;
    }
    let mut targets = Vec::new();
    for file in &snapshot.files {
        let path = file.path.as_str();
        let text = file.after.as_str();
        if !applicable(path) {
            continue;
        }
        if text.is_empty() {
            // A patch excerpt cannot stand in for the full file passed to Semgrep.
            if crate::hunks::lines(&file.patch)
                .is_some_and(|lines| lines.iter().any(|(_, head, _)| head.is_some()))
            {
                limits.push(format!(
                    "Semgrep requires the full head file for {path}; only its patch was available."
                ));
            }
            continue;
        }
        if !safe_path(path) || counts[path] != 1 {
            limits.push("Skipped files with invalid or duplicate paths.".into());
        } else if text.len() > TARGET_BYTES || text.contains('\0') {
            limits.push(format!("File {path} exceeds scan limits."));
        } else {
            targets.push((path, text));
        }
    }
    targets
}

fn executable(directories: &[PathBuf]) -> Option<PathBuf> {
    directories
        .iter()
        .map(|dir| dir.join("semgrep"))
        .find(|path| {
            fs::metadata(path).is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            })
        })
}

struct Prepared<'a> {
    scratch: TempDir,
    work: PathBuf,
    rules: PathBuf,
    files: Vec<(&'a str, usize)>,
}

impl<'a> Prepared<'a> {
    fn new(targets: Vec<(&'a str, &str)>, limits: &mut Vec<String>) -> io::Result<Self> {
        let scratch = tempfile::Builder::new().prefix("jidoka-scan-").tempdir()?;
        let work = scratch.path().join("source");
        let rules = scratch.path().join("rules.yml");
        fs::create_dir(&work)?;
        fs::write(&rules, RULE)?;
        // An empty local ignore file prevents default exclusions such as test directories.
        fs::write(work.join(".semgrepignore"), "")?;
        let mut files = Vec::new();
        for (path, text) in targets {
            let destination = work.join(path);
            let parent = destination.parent().unwrap_or(&work);
            let result = fs::create_dir_all(parent).and_then(|()| {
                // Keep original Git paths. Exclusive creation handles filesystem name collisions.
                OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&destination)?
                    .write_all(text.as_bytes())
            });
            if result.is_ok() {
                files.push((path, text.lines().count()));
            } else {
                limits.push(format!("Could not create a temporary copy of {path}."));
            }
        }
        Ok(Self {
            scratch,
            work,
            rules,
            files,
        })
    }

    fn command(&self, executable: &Path, search_path: &OsStr) -> Command {
        let root = self.scratch.path();
        let mut command = Command::new(executable);
        command
            .current_dir(&self.work)
            .env_clear()
            .env("PATH", search_path)
            .env("HOME", root)
            .env("XDG_CONFIG_HOME", root)
            .env("XDG_CACHE_HOME", root)
            .env("TMPDIR", root)
            .env("SEMGREP_SEND_METRICS", "off")
            .env("SEMGREP_ENABLE_VERSION_CHECK", "0");
        command
            .args([
                "scan",
                "--oss-only",
                "--json",
                "--quiet",
                "--metrics=off",
                "--disable-version-check",
                "--no-git-ignore",
                "--disable-nosem",
                "--no-rewrite-rule-ids",
                "--jobs=1",
                "--timeout=5",
                "--max-memory=256",
            ])
            .arg(format!("--max-target-bytes={TARGET_BYTES}"))
            .arg("--config")
            .arg(&self.rules)
            .arg("--")
            .args(self.files.iter().map(|(path, _)| *path));
        command
    }
}

#[derive(Debug, PartialEq, Eq)]
enum RunError {
    Deadline,
    Size,
    Io,
}

impl RunError {
    fn description(&self) -> &'static str {
        match self {
            Self::Deadline => "Semgrep exceeded the scan time limit.",
            Self::Size => "Semgrep output exceeded the size limit.",
            Self::Io => "Could not run Semgrep locally.",
        }
    }
}

fn run(
    command: &mut Command,
    timeout: Duration,
    cap: usize,
) -> Result<(ExitStatus, Vec<u8>), RunError> {
    let deadline = Instant::now() + timeout;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(|_| RunError::Io)?;
    let result = read_output(&mut child, deadline, cap);
    if result.is_err() {
        // process_group(0) gave this child and its descendants their own process group.
        unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

fn read_output(
    child: &mut Child,
    deadline: Instant,
    cap: usize,
) -> Result<(ExitStatus, Vec<u8>), RunError> {
    let mut stdout = child.stdout.take().ok_or(RunError::Io)?;
    let mut descriptor = libc::pollfd {
        fd: stdout.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    let mut output = Vec::new();
    let mut buffer = [0; 16_384];
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(RunError::Deadline);
        }
        // The descriptor belongs to the live stdout pipe, with room for one pollfd.
        let ready = unsafe {
            libc::poll(
                &mut descriptor,
                1,
                remaining.as_millis().clamp(1, i32::MAX as u128) as i32,
            )
        };
        if ready == 0 {
            continue;
        }
        if ready < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(RunError::Io);
        }
        if descriptor.revents & libc::POLLNVAL != 0 {
            return Err(RunError::Io);
        }
        let chunk = buffer.len().min(cap + 1 - output.len());
        let read = match stdout.read(&mut buffer[..chunk]) {
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            result => result.map_err(|_| RunError::Io)?,
        };
        if read == 0 {
            break;
        }
        output.extend_from_slice(&buffer[..read]);
        if output.len() > cap {
            return Err(RunError::Size);
        }
    }
    loop {
        if let Some(status) = child.try_wait().map_err(|_| RunError::Io)? {
            return Ok((status, output));
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(RunError::Deadline);
        }
        thread::sleep(remaining.min(Duration::from_millis(10)));
    }
}

#[derive(Deserialize)]
struct SemgrepOutput {
    version: Option<String>,
    paths: ScannedPaths,
    errors: Vec<Value>,
    results: Vec<Value>,
}

#[derive(Deserialize)]
struct ScannedPaths {
    scanned: Vec<String>,
}

fn normalize(path: &str) -> &str {
    path.strip_prefix("./").unwrap_or(path)
}

fn result(output: &[u8], targets: &[(&str, usize)], report: &mut Scan) {
    let Ok(output) = serde_json::from_slice::<SemgrepOutput>(output) else {
        report
            .limits
            .push("Semgrep returned an invalid result.".into());
        return;
    };
    if let Some(version) = output.version.filter(|version| {
        version.len() <= 32
            && version.split('.').count() == 3
            && version
                .split('.')
                .all(|part| !part.is_empty() && part.bytes().all(|c| c.is_ascii_digit()))
    }) {
        report.version = version;
    } else {
        report
            .limits
            .push("Semgrep version is missing or invalid.".into());
    }

    let scanned: HashSet<_> = output
        .paths
        .scanned
        .iter()
        .map(|path| normalize(path))
        .collect();
    let target_lines: HashMap<_, _> = targets.iter().copied().collect();
    let error_paths: HashSet<_> = output
        .errors
        .iter()
        .filter_map(|error| error["path"].as_str().map(normalize))
        .collect();
    if !output.errors.is_empty() {
        report.limits.push("Semgrep reported scan errors.".into());
    }
    if scanned.iter().any(|path| !target_lines.contains_key(path)) {
        report
            .limits
            .push("Semgrep reported paths outside the scan.".into());
    }

    let mut covered = HashSet::new();
    for &(path, _) in targets {
        if error_paths.contains(path) {
            report
                .limits
                .push(format!("Semgrep failed to finish scanning {path}."));
        } else if scanned.contains(path) {
            covered.insert(path);
            report.covered.push(path.to_owned());
        }
    }
    if targets.len() != covered.len() {
        report
            .limits
            .push("Semgrep coverage is incomplete for the prepared files.".into());
    }

    let mut misplaced = false;
    let mut seen = HashSet::new();
    for item in &output.results {
        let Some((path, rule, line, message)) = signal_parts(item) else {
            misplaced = true;
            continue;
        };
        if !scanned.contains(path)
            || target_lines
                .get(path)
                .is_none_or(|size| line == 0 || line > *size)
        {
            misplaced = true;
            continue;
        }
        if !covered.contains(path) || !seen.insert((path, rule, line, message)) {
            continue;
        }
        if report.signals.len() == SIGNALS {
            report
                .limits
                .push("Semgrep findings exceeded the reporting limit.".into());
            break;
        }
        report.signals.push(Signal {
            path: path.to_owned(),
            rule: rule.to_owned(),
            line,
            message: message.to_owned(),
        });
    }
    if misplaced {
        report
            .limits
            .push("Semgrep returned findings with invalid data or locations.".into());
    }
}

fn signal_parts(signal: &Value) -> Option<(&str, &str, usize, &str)> {
    fn field(value: &Value, limit: usize) -> Option<&str> {
        value.as_str().filter(|text| {
            !text.is_empty() && text.len() <= limit && !text.chars().any(char::is_control)
        })
    }
    Some((
        normalize(signal["path"].as_str()?),
        field(&signal["check_id"], 120)?,
        signal["start"]["line"].as_u64()?.try_into().ok()?,
        field(&signal["extra"]["message"], 400)?,
    ))
}

fn scan_using(snapshot: &Snapshot, configured_path: impl FnOnce() -> Option<OsString>) -> Scan {
    let mut report = Scan::default();
    let targets = targets(snapshot, &mut report.limits);
    if targets.is_empty() {
        return report;
    }
    let configured_path = configured_path();
    // Use the same absolute directories for discovery and for helpers launched from scratch.
    let directories: Vec<_> = env::split_paths(
        configured_path
            .as_deref()
            .unwrap_or(OsStr::new(DEFAULT_PATH)),
    )
    .filter(|directory| directory.is_absolute())
    .collect();
    let Some(executable) = executable(&directories) else {
        report
            .limits
            .push("Semgrep CE is unavailable for files with applicable rules.".into());
        return report;
    };
    let Ok(search_path) = env::join_paths(directories) else {
        report.limits.push("Invalid Semgrep search path.".into());
        return report;
    };
    for batch in targets.chunks(BATCH_SIZE) {
        let Ok(prepared) = Prepared::new(batch.to_vec(), &mut report.limits) else {
            report
                .limits
                .push("Could not prepare the Semgrep scan.".into());
            continue;
        };
        if prepared.files.is_empty() {
            continue;
        }
        match run(
            &mut prepared.command(&executable, &search_path),
            SCAN_TIME,
            OUTPUT_BYTES,
        ) {
            Ok((status, output)) => {
                if !status.success() {
                    report.limits.push("Semgrep exited with an error.".into());
                }
                result(&output, &prepared.files, &mut report);
            }
            Err(error) => report.limits.push(error.description().into()),
        }
    }
    report
}

pub fn scan(snapshot: &Snapshot) -> Scan {
    let mut report = scan_using(snapshot, || env::var_os("PATH"));
    let mut seen = HashSet::new();
    report.limits.retain(|limit| seen.insert(limit.clone()));
    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contracts::SourceFile;
    use serde_json::json;

    fn file(path: &str, text: &str) -> SourceFile {
        SourceFile {
            path: path.into(),
            patch: "synthetic patch".into(),
            before: "synthetic base".into(),
            after: text.into(),
        }
    }

    fn snapshot(files: Vec<SourceFile>) -> Snapshot {
        Snapshot {
            url: "https://github.com/owner/project/pull/3".into(),
            repo: "owner/project".into(),
            number: 3,
            base: "a".repeat(40),
            head: "b".repeat(40),
            intent: Vec::new(),
            limits: Vec::new(),
            files,
            head_context: Vec::new(),
            diff: None,
        }
    }

    fn hit(path: &str, line: Value) -> Value {
        json!({
            "path": path, "check_id": "python-subprocess-shell",
            "start": {"line": line}, "extra": {"message": "Review this fixture."},
        })
    }

    #[test]
    fn no_applicable_rule_is_a_normal_outcome() {
        let input = snapshot(vec![
            file("src/worker.rs", "fn fixture() {}"),
            file("ui/view.ts", "const view = 1;"),
            file("Makefile", "example:"),
            file("README.md", "Fixture documentation."),
            file("removed.py", ""),
        ]);
        let scan = scan_using(&input, || panic!("No executable should be needed"));
        assert!(
            scan.signals.is_empty()
                && scan.covered.is_empty()
                && scan.limits.is_empty()
                && scan.version.is_empty()
        );
    }

    #[test]
    fn patch_only_python_is_not_counted_as_scanned() {
        let mut changed = file("changed.py", "");
        changed.patch = "@@ -4 +4 @@\n-before()\n+after()".into();
        let mut removed = file("removed.py", "");
        removed.patch = "@@ -1 +0,0 @@\n-gone()".into();
        let report = scan_using(&snapshot(vec![changed, removed]), || {
            panic!("no full files")
        });
        assert!(report.covered.is_empty());
        assert_eq!(
            report.limits,
            ["Semgrep requires the full head file for changed.py; only its patch was available."]
        );
    }

    #[test]
    fn missing_executable_reports_a_scan_error_only_when_applicable() {
        let scan = scan_using(&snapshot(vec![file("app.py", "pass\n")]), || {
            Some(OsString::new())
        });
        assert!(scan.covered.is_empty() && scan.signals.is_empty());
        assert!(
            scan.limits
                .iter()
                .any(|limit| limit.contains("is unavailable"))
        );
    }

    #[test]
    fn prepares_original_paths_in_isolation_and_uses_only_local_rules() {
        let path = "tests/fixtures/module with spaces.pyi";
        let input = snapshot(vec![
            file(path, "ready: bool\r\n"),
            file("notes.md", "Fixture"),
            file("../out.py", "value = 1"),
            file("repeat.py", "value = 2"),
            file("repeat.py", "value = 3"),
            file("oversized.py", &"x".repeat(TARGET_BYTES + 1)),
        ]);
        let mut limits = Vec::new();
        let targets = targets(&input, &mut limits);
        assert_eq!(targets, [(path, "ready: bool\r\n")]);
        assert!(limits.iter().any(|limit| limit.contains("duplicate paths")));
        assert!(limits.iter().any(|limit| limit.contains("oversized.py")));
        let work = {
            let prepared = Prepared::new(targets, &mut limits).unwrap();
            assert_eq!(
                fs::read(prepared.work.join(path)).unwrap(),
                b"ready: bool\r\n"
            );
            assert_eq!(fs::read_to_string(&prepared.rules).unwrap(), RULE);
            assert_eq!(prepared.files, [(path, 1)]);
            let command = prepared.command(Path::new("/local/semgrep"), OsStr::new(DEFAULT_PATH));
            let args: Vec<_> = command.get_args().collect();
            for flag in [
                "--oss-only",
                "--metrics=off",
                "--disable-version-check",
                "--no-git-ignore",
                "--disable-nosem",
            ] {
                assert!(args.iter().any(|arg| *arg == flag));
            }
            assert_eq!(args[args.len() - 2], "--");
            assert_eq!(args[args.len() - 1], path);
            let env: HashMap<_, _> = command.get_envs().collect();
            for secret in [
                "SEMGREP_APP_TOKEN",
                "JIDOKA_API_KEY",
                "HTTPS_PROXY",
                "PYTHONPATH",
            ] {
                assert!(!env.contains_key(std::ffi::OsStr::new(secret)));
            }
            assert_eq!(
                env[std::ffi::OsStr::new("HOME")].unwrap(),
                prepared.scratch.path().as_os_str()
            );
            assert_eq!(
                env[std::ffi::OsStr::new("SEMGREP_SEND_METRICS")].unwrap(),
                "off"
            );
            prepared.work.clone()
        };
        assert!(!work.exists());
    }

    #[test]
    fn uses_absolute_custom_path_for_tool_and_helpers() {
        let tools = tempfile::tempdir().unwrap();
        let bin = tools.path().join("bin");
        let runtime = tools.path().join("runtime");
        fs::create_dir(&bin).unwrap();
        fs::create_dir(&runtime).unwrap();
        let fixture = bin.join("semgrep");
        let helper = runtime.join("jidoka_fixture_runtime");
        fs::write(&fixture, "#!/bin/sh\nexec jidoka_fixture_runtime\n").unwrap();
        fs::write(
            &helper,
            r#"#!/bin/sh
directory="${0%/*}"
[ "$PATH" = "${directory%/*}/bin:$directory" ] || exit 1
printf '%s\n' '{"version":"1.146.0","paths":{"scanned":["app.py"]},"errors":[],"results":[]}'
"#,
        )
        .unwrap();
        for script in [&fixture, &helper] {
            fs::set_permissions(script, fs::Permissions::from_mode(0o700)).unwrap();
        }
        let path = env::join_paths([
            Path::new(""),
            Path::new("."),
            &bin,
            Path::new("relative/helpers"),
            &runtime,
            Path::new(""),
        ])
        .unwrap();
        let report = scan_using(&snapshot(vec![file("app.py", "pass\n")]), || Some(path));
        assert!(report.limits.is_empty(), "{:?}", report.limits);
        assert_eq!(report.covered, ["app.py"]);
    }

    #[test]
    fn deduplicates_limits_in_first_occurrence_order_even_without_scan_targets() {
        let report = scan(&snapshot(vec![
            file("../outside.py", "pass\n"),
            file("oversized.py", &"x".repeat(TARGET_BYTES + 1)),
            file("repeat.py", "pass\n"),
            file("repeat.py", "pass\n"),
        ]));
        assert!(report.covered.is_empty());
        assert_eq!(
            report.limits,
            [
                "Skipped files with invalid or duplicate paths.",
                "File oversized.py exceeds scan limits.",
            ]
        );
    }

    #[test]
    fn reports_actual_coverage_and_rejects_unmapped_or_invalid_signals() {
        let path = "package/module.pyi";
        let output = json!({
            "version": "1.146.0",
            "paths": {"scanned": [format!("./{path}"), "broken.py", "../outside.py"]},
            "errors": [{"path": "./broken.py", "message": "Synthetic parse error"}],
            "results": [
                hit(path, json!(2)), hit(path, json!(2)), hit(path, json!(3)),
                hit(path, json!(true)), hit("broken.py", json!(1)), hit("../outside.py", json!(1)),
            ]
        });
        let mut scan = Scan::default();
        result(
            &serde_json::to_vec(&output).unwrap(),
            &[(path, 2), ("broken.py", 1), ("skipped.py", 1)],
            &mut scan,
        );
        assert_eq!(scan.version, "1.146.0");
        assert_eq!(scan.covered, [path]);
        assert_eq!(scan.signals.len(), 1);
        assert_eq!(
            (scan.signals[0].path.as_str(), scan.signals[0].line),
            (path, 2)
        );
        for message in [
            "broken.py",
            "invalid data or locations",
            "coverage is incomplete",
            "paths outside the scan",
        ] {
            assert!(
                scan.limits.iter().any(|limit| limit.contains(message)),
                "{:?}",
                scan.limits
            );
        }
    }

    #[test]
    fn malformed_output_remains_distinct_from_a_clean_scan() {
        let mut scan = Scan::default();
        result(b"not json", &[("a.py", 1)], &mut scan);
        assert!(scan.signals.is_empty() && scan.covered.is_empty() && !scan.limits.is_empty());
    }

    #[test]
    fn process_output_and_time_are_bounded() {
        let mut oversized = Command::new("/bin/sh");
        oversized.args(["-c", "printf 0123456789"]);
        assert_eq!(
            run(&mut oversized, Duration::from_secs(1), 9).unwrap_err(),
            RunError::Size
        );

        let mut slow = Command::new("/bin/sh");
        slow.args(["-c", "/bin/sleep 5 & wait"]);
        assert_eq!(
            run(&mut slow, Duration::from_millis(50), 100).unwrap_err(),
            RunError::Deadline
        );
    }

    #[test]
    #[ignore = "requires a local Semgrep CE executable"]
    fn real_rule_matches_positive_and_reports_clean_file_as_covered() {
        let positive = "tests/a fixture.py";
        let negative = "app/negative.pyi";
        let input = snapshot(vec![
            file(
                positive,
                "import subprocess\nsubprocess.run('fixture', shell=True)  # nosemgrep\n",
            ),
            file(
                negative,
                "import subprocess\nsubprocess.run(['fixture'], shell=False)\n",
            ),
            file("also.rs", "fn fixture() {}"),
        ]);
        let scan = scan(&input);
        assert!(scan.limits.is_empty(), "{:?}", scan.limits);
        assert_eq!(scan.covered, [positive, negative]);
        assert_eq!(scan.signals.len(), 1);
        let signal = &scan.signals[0];
        assert_eq!(
            (signal.rule.as_str(), signal.path.as_str(), signal.line),
            ("python-subprocess-shell", positive, 2)
        );
        assert!(!scan.version.is_empty());
    }
}
