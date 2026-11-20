use axum::{Json, Router, routing::post};
use jidoka_code::{
    contracts::{Snapshot, SourceFile},
    provider::Provider,
    review_snapshot, web,
};
use reqwest::{Client, StatusCode, header, redirect};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};
use tokio::{net::TcpListener, sync::oneshot, task::JoinHandle};

fn serve(listener: TcpListener, app: Router) -> (oneshot::Sender<()>, JoinHandle<()>) {
    let (shutdown, signal) = oneshot::channel();
    let task = tokio::spawn(async move {
        axum::serve(listener, app)
            .with_graceful_shutdown(async {
                let _ = signal.await;
            })
            .await
            .unwrap();
    });
    (shutdown, task)
}

async fn get_html(client: &Client, url: &str) -> String {
    let response = client.get(url).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::OK, "{url}");
    response.text().await.unwrap()
}

/// Exercise the web and provider wire protocols. Only GitHub collection and AI text are fixtures.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cross_stack_report_through_http_and_restart() {
    check_service_restart(false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn scanner_limits_remain_visible_through_http_after_restart() {
    check_service_restart(true).await;
}

async fn check_service_restart(scan_limited: bool) {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("fixtures/pilot-replay.json")).unwrap();
    let case = cases
        .iter()
        .find(|case| case["name"] == "go-sql-typescript")
        .unwrap();
    let mut snapshot: Snapshot = serde_json::from_value(case["snapshot"].clone()).unwrap();
    let scanner_limit = "File fuori dai limiti di scansione: fixtures/oversized.py.";
    if scan_limited {
        // The scanner rejects this input before looking for an installed executable.
        snapshot.files.push(SourceFile {
            path: "fixtures/oversized.py".into(),
            patch: String::new(),
            before: String::new(),
            after: "x = 1\n".repeat(5_000),
        });
    }
    let file_count = snapshot.files.len();
    let submitted_url = snapshot.url.clone();
    let allowed = HashSet::from([snapshot.repo.clone()]);
    let replies = Arc::new(Mutex::new(
        case["replies"].as_array().unwrap().clone().into_iter(),
    ));
    let calls = replies.clone();
    let model = Router::new().route(
        "/chat",
        post(move |Json(body): Json<Value>| {
            let calls = calls.clone();
            async move {
                assert_eq!(body["model"], "synthetic");
                let payload: Value =
                    serde_json::from_str(body["messages"][1]["content"].as_str().unwrap()).unwrap();
                assert_eq!(
                    payload["snapshot"]["files"].as_array().unwrap().len(),
                    file_count
                );
                let content = calls.lock().unwrap().next().expect("Unexpected model call");
                Json(json!({"choices": [{
                    "finish_reason": "stop",
                    "message": {"content": content.to_string()},
                }]}))
            }
        }),
    );
    let receiver = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/chat", receiver.local_addr().unwrap());
    let (stop_model, model_task) = serve(receiver, model);
    let label = format!("{url} (synthetic)");
    let temp = tempfile::tempdir().unwrap();
    let db = temp.path().join("reviews.db");
    let router = web::router(&db, &label, &allowed).unwrap();
    web::recover(&db, &label).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let base = format!("http://{address}");
    let (stop_ui, ui) = serve(listener, router);
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
    assert_eq!(response.status(), StatusCode::SEE_OTHER);
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
    let permalink = format!("{base}{location}");
    let html = get_html(&client, &permalink).await;
    let expected_status = if scan_limited {
        "Parziale"
    } else {
        "Completata"
    };
    for text in [
        "Dove concentrarti",
        "api/capacity.go",
        "Problemi verificati",
        expected_status,
    ] {
        assert!(html.contains(text), "missing {text}: {html}");
    }
    if scan_limited {
        assert!(html.contains("Limiti Semgrep"));
        assert!(html.contains(scanner_limit));
    } else {
        assert!(html.contains("Nessuna regola Semgrep applicabile"));
    }
    assert!(replies.lock().unwrap().next().is_none());
    stop_ui.send(()).unwrap();
    ui.await.unwrap();
    let restarted = web::router(&db, &label, &allowed).unwrap();
    web::recover(&db, &label).unwrap();
    let (stop_ui, ui) = serve(TcpListener::bind(address).await.unwrap(), restarted);
    let history = get_html(&client, &base).await;
    assert!(history.contains("Cronologia"));
    assert!(history.contains(&format!(
        r#"<a href="{location}">{submitted_url}</a> · {expected_status}"#
    )));
    assert_eq!(get_html(&client, &permalink).await, html);
    stop_ui.send(()).unwrap();
    ui.await.unwrap();
    stop_model.send(()).unwrap();
    model_task.await.unwrap();
}
