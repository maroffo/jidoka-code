//! The Compose reviewer container accepts one job at a time on a private Unix socket.
use anyhow::{Context, Result, ensure};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, PermissionsExt, chown},
            net::{UnixListener, UnixStream},
            process::CommandExt,
        },
    },
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

const USER: u32 = 10002;
const MAX_RESULT: u64 = 8 * 1024 * 1024;

pub fn serve() -> Result<()> {
    let path = Path::new("/control/agy.sock");
    if let Ok(meta) = fs::symlink_metadata(path) {
        ensure!(meta.file_type().is_socket(), "Unexpected AGY control path");
        fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    chown(path, Some(10001), Some(10001))?;
    let (mut connection, _) = listener.accept()?;
    fs::remove_file(path)?;
    drop(listener);
    if let Err(error) = run(&mut connection) {
        // Send a controlled operational reason; provider diagnostics may include private data.
        let reason = if error.is::<CredentialError>() {
            "credentials"
        } else {
            "runner"
        };
        let _ = serde_json::to_writer(
            connection,
            &serde_json::json!({"status":"ERROR","reason":reason}),
        );
        eprintln!("AGY session ended without a verdict ({reason})");
    }
    // Exiting the container tears down even detached tools before another PR enters.

    Ok(())
}

fn run(mut peer: &mut UnixStream) -> Result<()> {
    peer.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut reader = BufReader::new((&*peer).take(512));
    let mut job = String::new();
    let mut model = String::new();
    reader.read_line(&mut job)?;
    reader.read_line(&mut model)?;
    let id = job
        .strip_suffix('\n')
        .and_then(|s| s.strip_prefix("review-"))
        .context("Invalid job")?;
    ensure!(
        !id.is_empty() && id.len() <= 64 && id.bytes().all(|c| c.is_ascii_alphanumeric()),
        "Invalid job"
    );
    let model = model.strip_suffix('\n').context("Invalid model")?;
    ensure!(
        !model.is_empty() && model.len() <= 200 && !model.chars().any(char::is_control),
        "Invalid model"
    );
    let job = format!("/jobs/review-{id}");
    ensure!(
        Path::new(&job).join("review.json").is_file(),
        "Missing review manifest"
    );
    let home = tempfile::Builder::new().prefix("agy-home-").tempdir()?;
    chown(home.path(), Some(USER), Some(USER))?;
    let output = tempfile::tempfile()?;
    let prompt = format!(
        "{}\nThe review workspace is {job}.",
        include_str!("../runner/prompt.txt")
    );
    // Refresh outside the agent identity. Never pass refresh tokens, signing keys or the ADC file to tools.
    let mut auth = ProcessGroup(
        Command::new("/usr/local/bin/python3")
            .args(["-I", "/usr/local/lib/jidoka/adc.py"])
            .env_clear()
            .env(
                "GOOGLE_CLOUD_QUOTA_PROJECT",
                std::env::var("GOOGLE_CLOUD_QUOTA_PROJECT")?,
            )
            .env("TZ", "UTC")
            .process_group(0)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?,
    );
    let mut ready = String::new();
    let stdout = auth
        .0
        .stdout
        .take()
        .context("Missing credential helper output")?;
    let mut readiness = libc::pollfd {
        fd: stdout.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    if unsafe { libc::poll(&mut readiness, 1, 45_000) } <= 0 {
        return Err(CredentialError.into());
    }
    BufReader::new(stdout.take(16)).read_line(&mut ready)?;
    let port: u16 = ready.trim().parse().map_err(|_| CredentialError)?;
    let metadata = format!("127.0.0.1:{port}");
    let mut cli = Command::new("/usr/local/bin/agy");
    cli.current_dir(home.path())
        .env_clear()
        .env("HOME", home.path())
        .env("PATH", "/usr/local/bin:/usr/bin:/bin")
        .env("AGY_ADC_AUTH", "true")
        .env("GCE_METADATA_HOST", &metadata)
        .env("GCE_METADATA_IP", &metadata)
        .env("NO_PROXY", "localhost,127.0.0.1")
        .env(
            "GOOGLE_CLOUD_LOCATION",
            std::env::var("GOOGLE_CLOUD_LOCATION").unwrap_or_else(|_| "global".into()),
        )
        .env(
            "GOOGLE_CLOUD_QUOTA_PROJECT",
            std::env::var("GOOGLE_CLOUD_QUOTA_PROJECT")?,
        )
        .uid(USER)
        .gid(USER)
        .process_group(0)
        .args([
            "-p",
            &prompt,
            "--dangerously-skip-permissions",
            "--disable-slash-commands",
            "--model",
            model,
            "--add-dir",
            &job,
            "--output-format",
            "json",
            "--json-schema",
            include_str!("../runner/verdict.json"),
            "--print-timeout",
            "30m",
        ])
        .stdin(Stdio::null())
        .stdout(output.try_clone()?)
        .stderr(Stdio::null());
    let mut process = ProcessGroup(cli.spawn()?);
    let deadline = Instant::now() + Duration::from_secs(32 * 60);
    let status = loop {
        if let Some(status) = process.0.try_wait()? {
            break status;
        }
        let mut poll = libc::pollfd {
            fd: peer.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // The controller sends no bytes after the two header lines. EOF means cancellation.
        let ready = unsafe { libc::poll(&mut poll, 1, 0) };
        ensure!(
            ready == 0 && Instant::now() < deadline && output.metadata()?.len() <= MAX_RESULT,
            "AGY session canceled or exceeded runner limits"
        );
        thread::sleep(Duration::from_millis(250));
    };
    drop(process);
    ensure!(
        output.metadata()?.len() <= MAX_RESULT,
        "AGY result too large"
    );
    let mut result = output;
    result.seek(SeekFrom::Start(0))?;
    let mut value: serde_json::Value = serde_json::from_reader(result.take(MAX_RESULT))?;
    ensure!(value.is_object(), "Invalid AGY response");
    if !status.success() {
        value["status"] = "ERROR".into();
    }
    // Return only the verdict and meter, never raw tool output or CLI diagnostics.
    serde_json::to_writer(
        &mut peer,
        &serde_json::json!({
            "status":value["status"],"usage":value["usage"],"structured_output":value["structured_output"],
            "denied_actions":value.get("denied_actions").cloned().unwrap_or_else(|| serde_json::json!([]))
        }),
    )?;
    peer.flush()?;
    Ok(())
}

#[derive(Debug)]
struct CredentialError;
impl std::fmt::Display for CredentialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("AGY credential setup failed")
    }
}
impl std::error::Error for CredentialError {}

struct ProcessGroup(Child);
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        // AGY and tools normally inherit the new process group.
        unsafe {
            libc::kill(-(self.0.id() as i32), libc::SIGKILL);
        }
        let _ = self.0.wait();
    }
}
