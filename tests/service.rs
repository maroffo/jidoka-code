use axum::{Json, Router, routing::post};
use jidoka_code::{contracts::Snapshot, provider::Provider, review_snapshot, web};
use reqwest::{Client, header, redirect};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;

/// Exercise the web and provider wire protocols. Only GitHub collection and AI text are fixtures.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cross_stack_report_through_http_and_restart() {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/pilot-replay.json")).unwrap();
    let case = &cases[0];
    let snapshot: Snapshot = serde_json::from_value(case["snapshot"].clone()).unwrap();
    let replies = Arc::new(Mutex::new(
        case["replies"].as_array().unwrap().clone().into_iter(),
    ));
    let calls = replies.clone();
    let model=Router::new().route("/chat",post(move |Json(body):Json<Value>| {
        let calls=calls.clone();
        async move {
            assert_eq!(body["model"],"synthetic");
            let payload:Value=serde_json::from_str(body["messages"][1]["content"].as_str().unwrap()).unwrap();
            assert_eq!(payload["snapshot"]["files"].as_array().unwrap().len(),3);
            let content=calls.lock().unwrap().next().expect("Unexpected model call");
            Json(json!({"choices":[{"finish_reason":"stop","message":{"content":content.to_string()}}]}))
        }
    }));
    let receiver = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/chat", receiver.local_addr().unwrap());
    let model_task = tokio::spawn(async move {
        axum::serve(receiver, model).await.unwrap();
    });
    let label = format!("{url} (synthetic)");
    let temp = tempfile::tempdir().unwrap();
    let db = temp.path().join("reviews.db");
    let router = web::router(&db, &label).unwrap();
    web::recover(&db, &label).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let ui = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    let client = Client::builder()
        .no_proxy()
        .redirect(redirect::Policy::none())
        .build()
        .unwrap();
    let form = client.get(&base).send().await.unwrap();
    let cookie = form.headers()[header::SET_COOKIE]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    let html = form.text().await.unwrap();
    let token = html
        .split_once("name=\"csrf_token\"")
        .unwrap()
        .1
        .split_once("value=\"")
        .unwrap()
        .1
        .split('"')
        .next()
        .unwrap();
    let response = client
        .post(&base)
        .header(header::COOKIE, cookie)
        .header(header::ORIGIN, &base)
        .form(&[
            ("csrf_token", token),
            ("url", snapshot.url.as_str()),
            ("consent", "yes"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 303);
    let location = response.headers()[header::LOCATION]
        .to_str()
        .unwrap()
        .to_owned();
    let database = db.clone();
    tokio::task::spawn_blocking(move || {
        let provider = Provider::new(&url, "synthetic", String::new()).unwrap();
        assert!(
            web::run_one(&database, |queued| {
                assert_eq!(queued, snapshot.url);
                review_snapshot(snapshot, |system, data| provider.ask(system, data))
            })
            .unwrap()
        );
    })
    .await
    .unwrap();
    let html = client
        .get(format!("{base}{location}"))
        .send()
        .await
        .unwrap()
        .text()
        .await
        .unwrap();
    for text in [
        "Dove concentrarti",
        "api/capacity.go",
        "Problemi verificati",
        "Completata",
    ] {
        assert!(html.contains(text), "missing {text}: {html}");
    }
    assert!(replies.lock().unwrap().next().is_none());
    ui.abort();
    web::recover(&db, &label).unwrap();
    let history = rusqlite::Connection::open(db).unwrap();
    let status: String = history
        .query_row("SELECT status FROM reviews WHERE id=1", [], |r| r.get(0))
        .unwrap();
    assert_eq!(status, "completed");
    model_task.abort();
}
