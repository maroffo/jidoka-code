mod agy;
mod agy_runner;

use agy::Reviewer;
use anyhow::{Context, Result};
use jidoka_code::{source, web};
use std::{
    collections::HashSet,
    env,
    path::{Path, PathBuf},
    sync::mpsc,
    time::{Duration, Instant},
};
use tokio::{
    net::TcpListener,
    signal::unix::{SignalKind, signal},
    sync::oneshot,
    task,
};

fn main() -> Result<()> {
    if env::args().skip(1).eq(["--agy-runner"]) {
        return agy_runner::serve();
    }
    let provider = Reviewer::from_env()?;
    let repositories: HashSet<String> = env::var("JIDOKA_REPOS")
        .unwrap_or_default()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase)
        .collect();
    let db = PathBuf::from(env::var("JIDOKA_DB").unwrap_or_else(|_| "data/reviews.sqlite3".into()));
    if let Some(parent) = db.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let args: Vec<_> = env::args().skip(1).collect();
    if !args.is_empty() {
        anyhow::ensure!(
            args.len() == 2 && args[0] == "--replay-review",
            "Usage: jidoka-code [--replay-review ID]"
        );
        let id = web::session::replay(&db, args[1].parse()?, provider.label(), &repositories)?;
        println!("Queued review {id}");
        return Ok(());
    }
    let address = env::var("JIDOKA_BIND").unwrap_or_else(|_| "127.0.0.1".into());
    let port = env::var("JIDOKA_PORT")
        .unwrap_or_else(|_| "8080".into())
        .parse::<u16>()?;
    tokio::runtime::Runtime::new()?.block_on(async move {
        let listener = TcpListener::bind((address.as_str(), port)).await?;
        let _jobs_lock = provider.recover_jobs()?;
        web::recover(&db, provider.label())?;
        let app = web::router(&db, provider.label(), &repositories)?;
        let mut term = signal(SignalKind::terminate())?;
        let mut interrupt = signal(SignalKind::interrupt())?;
        supervise(
            listener,
            app,
            async move {
                tokio::select! { _ = term.recv() => {}, _ = interrupt.recv() => {} }
            },
            move |stop| work(&db, provider, &repositories, stop),
        )
        .await
    })
}

async fn supervise(
    listener: TcpListener,
    app: axum::Router,
    shutdown: impl Future<Output = ()>,
    work: impl FnOnce(mpsc::Receiver<()>) + Send + 'static,
) -> Result<()> {
    let (worker_stop, stopped) = mpsc::channel();
    let mut worker = task::spawn_blocking(move || work(stopped));
    let (server_stop, shutdown_http) = oneshot::channel::<()>();
    let mut server = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = shutdown_http.await;
            })
            .await
    });

    tokio::select! {
        _ = shutdown => {},
        result = &mut worker => {
            drop(server_stop);
            // An unexpected worker exit must take the listener out of service.
            server.abort();
            let _ = server.await;
            result.context("Review worker exited unexpectedly")?;
            anyhow::bail!("Review worker exited before shutdown");
        }
        result = &mut server => {
            drop(worker_stop);
            worker.await.context("Review worker exited unexpectedly")?;
            result??;
            anyhow::bail!("HTTP server exited before shutdown");
        }
    }
    drop(worker_stop);
    drop(server_stop);
    let (worker, server) = tokio::join!(worker, server);
    worker.context("Review worker exited unexpectedly")?;
    server??;
    Ok(())
}

fn poll(db: &Path, provider: &Reviewer, repositories: &HashSet<String>, next: &mut Instant) {
    if Instant::now() >= *next {
        if jidoka_code::automation::tick(db, provider.label(), repositories).is_err() {
            eprintln!("Could not complete repository polling");
        }
        *next = Instant::now() + Duration::from_secs(60);
    }
}

fn work(db: &Path, provider: Reviewer, repositories: &HashSet<String>, stop: mpsc::Receiver<()>) {
    let mut next_poll = Instant::now();
    while matches!(stop.try_recv(), Err(mpsc::TryRecvError::Empty)) {
        poll(db, &provider, repositories, &mut next_poll);
        let result = web::run_one_session(db, |id, url, expected_head| {
            let mut session = web::session::Session::open(db, id)?;
            let allowed = jidoka_code::automation::repositories_at(db, repositories)?;
            let previous = match session.replay_source()? {
                Some(original) => Some(original),
                None => web::latest_review(db, provider.label(), url)?,
            };
            let paths = previous
                .iter()
                .flat_map(|report| &report.report.findings)
                .map(|finding| finding.path.clone())
                .collect::<Vec<_>>();
            let collect_current = || {
                source::collect_repository(
                    url,
                    &allowed,
                    expected_head,
                    previous.as_ref().map(|r| r.head.as_str()),
                    &paths,
                )
            };
            let saved_origin = session.remember_origin(None)?;
            let (fresh, repository) = if let Some((base, head)) = session.revisions()? {
                anyhow::ensure!(
                    expected_head.is_none_or(|expected| expected == head),
                    "Checkpoint revision changed"
                );
                if expected_head.is_some() {
                    match source::resume_automatic_repository(
                        url,
                        &allowed,
                        &base,
                        &head,
                        saved_origin.as_deref(),
                    ) {
                        Err(e) if e.is::<source::BaseChanged>() => {
                            session.reset()?;
                            collect_current()?
                        }
                        result => result?,
                    }
                } else {
                    source::collect_repository_at(
                        url,
                        &allowed,
                        &base,
                        &head,
                        saved_origin.as_deref(),
                    )?
                }
            } else {
                collect_current()?
            };
            let recorded = session.remember_origin(Some(repository.source_repo()))?;
            anyhow::ensure!(
                recorded.as_deref() == Some(repository.source_repo()),
                "The source repository changed since the checkpoint"
            );
            let origin = repository.private_source_repo().map(str::to_owned);
            let (snapshot, prior) = if let Some(saved) = session.saved_inputs()? {
                anyhow::ensure!(
                    fresh.repo.eq_ignore_ascii_case(&saved.0.repo)
                        && fresh.base == saved.0.base
                        && fresh.head == saved.0.head,
                    "Checkpoint repository changed"
                );
                saved
            } else {
                let mut snapshot = fresh;
                if let Some(report) = &previous {
                    web::add_previous_questions(report, &mut snapshot);
                }
                let prior = web::previous_findings(db, provider.label(), &snapshot)?;
                session.save_inputs(&snapshot, &prior)?;
                (snapshot, prior)
            };
            let reviewed_repo = snapshot.repo.to_ascii_lowercase();
            let stopping = || !matches!(stop.try_recv(), Err(mpsc::TryRecvError::Empty));
            let eligible = || -> Result<()> {
                if stopping() {
                    return Err(web::session::Paused.into());
                }
                let allowed = jidoka_code::automation::repositories_at(db, repositories)?;
                anyhow::ensure!(
                    web::session::running(db, id)?
                        && allowed.contains(&reviewed_repo)
                        && origin.as_ref().is_none_or(|r| allowed.contains(r)),
                    "Review is no longer eligible"
                );
                Ok(())
            };
            eligible()?;
            let outcome = provider.review(&mut session, snapshot, &repository, &prior, || {
                poll(db, &provider, repositories, &mut next_poll);
                eligible()
            });
            if stopping() {
                return Err(web::session::Paused.into());
            }
            outcome
        });
        match result {
            Ok(true)
                if jidoka_code::automation::publish_ready(db, provider.label(), repositories)
                    .is_err() =>
            {
                eprintln!("Could not publish completed automatic reviews");
            }
            Err(_) => eprintln!("Could not update the review queue"),
            _ => {}
        }
        if stop.recv_timeout(Duration::from_millis(500)) != Err(mpsc::RecvTimeoutError::Timeout) {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[tokio::test]
    async fn shutdown_waits_for_worker_cleanup_and_releases_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let completed = Arc::new(AtomicBool::new(false));
        let flag = completed.clone();
        supervise(listener, axum::Router::new(), async {}, move |stop| {
            assert!(stop.recv().is_err());
            flag.store(true, Ordering::SeqCst);
        })
        .await
        .unwrap();
        assert!(completed.load(Ordering::SeqCst));
        assert!(TcpListener::bind(address).await.is_ok());
    }

    #[tokio::test]
    async fn worker_panic_stops_http_service() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let result = supervise(
            listener,
            axum::Router::new(),
            std::future::pending(),
            |_| panic!("fixture"),
        )
        .await;
        assert!(result.is_err());
        assert!(TcpListener::bind(address).await.is_ok());
    }
}
