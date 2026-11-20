use anyhow::{Context, Result, ensure};
use jidoka_code::{provider::Provider, review_snapshot, source, web};
use std::{
    collections::HashSet,
    env,
    path::{Path, PathBuf},
    sync::mpsc,
    time::Duration,
};
use tokio::{
    net::TcpListener,
    signal::unix::{SignalKind, signal},
    sync::oneshot,
    task,
};

fn required(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("Set {name}"))
}

fn main() -> Result<()> {
    let provider = Provider::new(
        &required("JIDOKA_PROVIDER_URL")?,
        &required("JIDOKA_MODEL")?,
        env::var("JIDOKA_API_KEY").unwrap_or_default(),
    )?;
    let repositories: HashSet<String> = required("JIDOKA_REPOS")?
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_ascii_lowercase)
        .collect();
    ensure!(!repositories.is_empty(), "Specify at least one repository");
    let db = PathBuf::from(env::var("JIDOKA_DB").unwrap_or_else(|_| "data/reviews.sqlite3".into()));
    if let Some(parent) = db.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let address = env::var("JIDOKA_BIND").unwrap_or_else(|_| "127.0.0.1".into());
    let port = env::var("JIDOKA_PORT")
        .unwrap_or_else(|_| "8080".into())
        .parse::<u16>()?;
    let app = web::router(&db, provider.label(), &repositories)?;
    tokio::runtime::Runtime::new()?.block_on(async move {
        let listener = TcpListener::bind((address.as_str(), port)).await?;
        web::recover(&db, provider.label())?;
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

fn work(db: &Path, provider: Provider, repositories: &HashSet<String>, stop: mpsc::Receiver<()>) {
    while matches!(stop.try_recv(), Err(mpsc::TryRecvError::Empty)) {
        let result = web::run_one(db, |url| {
            let snapshot = source::collect(url, repositories)?;
            review_snapshot(snapshot, |system, data| provider.ask(system, data))
        });
        if result.is_err() {
            eprintln!("Could not update the review queue");
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
