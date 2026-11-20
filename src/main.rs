use anyhow::{Context, Result, ensure};
use jidoka_code::{provider::Provider, review_snapshot, source, web};
use std::{
    collections::HashSet,
    env,
    path::{Path, PathBuf},
    thread,
    time::Duration,
};
use tokio::net::TcpListener;

fn required(name: &str) -> Result<String> {
    env::var(name).with_context(|| format!("Configurare {name}"))
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
    ensure!(
        !repositories.is_empty(),
        "Specificare almeno un repository pubblico"
    );
    let db = PathBuf::from(env::var("JIDOKA_DB").unwrap_or_else(|_| "data/reviews.sqlite3".into()));
    if let Some(parent) = db.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    let address = env::var("JIDOKA_BIND").unwrap_or_else(|_| "127.0.0.1".into());
    let port = env::var("JIDOKA_PORT")
        .unwrap_or_else(|_| "8080".into())
        .parse::<u16>()?;
    let app = web::router(&db, provider.label())?;
    tokio::runtime::Runtime::new()?.block_on(async move {
        let listener = TcpListener::bind((address.as_str(), port)).await?;
        web::recover(&db, provider.label())?;
        thread::Builder::new()
            .name("review-worker".into())
            .spawn(move || work(&db, provider, &repositories))?;
        axum::serve(listener, app).await?;
        Ok(())
    })
}

fn work(db: &Path, provider: Provider, repositories: &HashSet<String>) {
    loop {
        let result = web::run_one(db, |url| {
            let snapshot = source::collect(url, repositories)?;
            review_snapshot(snapshot, |system, data| provider.ask(system, data))
        });
        if result.is_err() {
            eprintln!("Impossibile aggiornare la coda di review");
        }
        thread::sleep(Duration::from_millis(500));
    }
}
