//! Dev-only HTTP bridge around the app's Tauri command surface.
//!
//! The UI normally talks to Rust over Tauri's IPC, which only exists inside a
//! real webview. That makes the app impossible to drive from a plain browser —
//! and on Linux CI/containers there is no signed macOS/iOS build to drive at
//! all. This bridge stands the app up on Tauri's mock runtime and re-exposes
//! `invoke` over `POST /invoke`, so `pnpm dev` in any browser (desktop or a
//! phone viewport) runs against the real database, the real feed fetcher and
//! the real AI providers.
//!
//! Build and run with:
//!
//! ```sh
//! cargo run --features devbridge -- --dev-bridge
//! ```
//!
//! It is behind a non-default cargo feature and is never part of a release
//! bundle.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use serde_json::{json, Value};
use tauri::test::{mock_builder, INVOKE_KEY};
use tauri::{Listener, Manager};

/// Events the frontend subscribes to. `emit` reaches the webview by evaluating
/// JavaScript, which the mock runtime discards, so the bridge mirrors them into
/// a buffer the browser polls instead.
const FORWARDED_EVENTS: &[&str] = &[
    crate::commands::editions::TODAY_LEDE_PROGRESS_EVENT,
    "theme_progress",
    "triage_progress",
    "model-download-progress",
    "skim-reader://offline-preload-progress",
    "skim-ai://mlx-download-progress",
];

/// How many emitted events to keep for slow pollers.
const EVENT_BUFFER: usize = 512;

#[derive(Clone)]
struct BufferedEvent {
    seq: u64,
    name: String,
    payload: Value,
}

#[derive(Default)]
struct EventBuffer {
    next_seq: u64,
    events: VecDeque<BufferedEvent>,
}

type SharedEvents = Arc<Mutex<EventBuffer>>;

pub fn run() {
    let _ = env_logger::try_init();

    let port: u16 = std::env::var("SKIM_BRIDGE_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(1421);

    let app = mock_builder()
        .plugin(tauri_plugin_opener::init())
        // The same plugin set the real app registers. Without skim-ai, picking
        // the MLX or Apple Intelligence tier panics on unmanaged state rather
        // than reporting that the tier needs a native build.
        .plugin(tauri_plugin_skim_ai::init())
        .invoke_handler(crate::invoke_handler())
        .build(tauri::generate_context!())
        .expect("failed to build bridge app");

    let handle = app.handle().clone();

    let data_dir = match std::env::var("SKIM_BRIDGE_DATA_DIR") {
        Ok(dir) => std::path::PathBuf::from(dir),
        Err(_) => handle
            .path()
            .app_data_dir()
            .expect("Failed to get app data directory"),
    };
    log::info!("dev bridge data dir: {}", data_dir.display());
    crate::init_state(&handle, data_dir);

    let events: SharedEvents = Arc::new(Mutex::new(EventBuffer::default()));
    for name in FORWARDED_EVENTS {
        let events = events.clone();
        let name = (*name).to_string();
        handle.listen_any(name.clone(), move |event| {
            let payload: Value = serde_json::from_str(event.payload()).unwrap_or(Value::Null);
            let mut buf = events.lock().expect("event buffer");
            buf.next_seq += 1;
            let seq = buf.next_seq;
            buf.events.push_back(BufferedEvent {
                seq,
                name: name.clone(),
                payload,
            });
            while buf.events.len() > EVENT_BUFFER {
                buf.events.pop_front();
            }
        });
    }

    // A webview is what carries the command context; the mock runtime never
    // paints it.
    let webview = tauri::WebviewWindowBuilder::new(&handle, "bridge", Default::default())
        .build()
        .expect("failed to build bridge webview");

    let server = Arc::new(
        tiny_http::Server::http(("127.0.0.1", port))
            .unwrap_or_else(|e| panic!("dev bridge cannot listen on 127.0.0.1:{port}: {e}")),
    );
    println!("skim dev bridge listening on http://127.0.0.1:{port}");

    // `get_ipc_response` blocks until the command resolves, so each request
    // needs its own thread or one slow summarize would stall the whole UI.
    let mut workers = Vec::new();
    for _ in 0..8 {
        let server = server.clone();
        let webview = webview.clone();
        let events = events.clone();
        workers.push(std::thread::spawn(move || loop {
            let Ok(request) = server.recv() else { return };
            handle_request(request, &webview, &events);
        }));
    }
    for worker in workers {
        let _ = worker.join();
    }
}

fn cors(response: tiny_http::Response<std::io::Cursor<Vec<u8>>>) -> tiny_http::Response<std::io::Cursor<Vec<u8>>> {
    let header = |k: &str, v: &str| {
        tiny_http::Header::from_bytes(k.as_bytes(), v.as_bytes()).expect("static header")
    };
    response
        .with_header(header("Access-Control-Allow-Origin", "*"))
        .with_header(header("Access-Control-Allow-Headers", "*"))
        .with_header(header("Access-Control-Allow-Methods", "POST, GET, OPTIONS"))
        .with_header(header("Content-Type", "application/json"))
}

fn respond(request: tiny_http::Request, status: u16, body: Value) {
    let response = cors(tiny_http::Response::from_data(body.to_string().into_bytes()))
        .with_status_code(status);
    let _ = request.respond(response);
}

fn handle_request(
    mut request: tiny_http::Request,
    webview: &tauri::WebviewWindow<tauri::test::MockRuntime>,
    events: &SharedEvents,
) {
    let method = request.method().clone();
    let url = request.url().to_string();

    if method == tiny_http::Method::Options {
        respond(request, 204, Value::Null);
        return;
    }

    if url.starts_with("/health") {
        respond(request, 200, json!({ "ok": true }));
        return;
    }

    if url.starts_with("/events") {
        let since: u64 = url
            .split_once("since=")
            .and_then(|(_, rest)| rest.split('&').next())
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        let buf = events.lock().expect("event buffer");
        let pending: Vec<Value> = buf
            .events
            .iter()
            .filter(|e| e.seq > since)
            .map(|e| json!({ "seq": e.seq, "event": e.name, "payload": e.payload }))
            .collect();
        let next = buf.next_seq;
        drop(buf);
        respond(request, 200, json!({ "next": next, "events": pending }));
        return;
    }

    if !url.starts_with("/invoke") {
        respond(request, 404, json!({ "error": "not found" }));
        return;
    }

    let mut body = String::new();
    if let Err(e) = std::io::Read::read_to_string(request.as_reader(), &mut body) {
        respond(request, 400, json!({ "error": format!("unreadable body: {e}") }));
        return;
    }
    let parsed: Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            respond(request, 400, json!({ "error": format!("bad json: {e}") }));
            return;
        }
    };
    let Some(cmd) = parsed.get("cmd").and_then(Value::as_str) else {
        respond(request, 400, json!({ "error": "missing cmd" }));
        return;
    };
    let payload = parsed.get("payload").cloned().unwrap_or(json!({}));

    let result = tauri::test::get_ipc_response(
        webview,
        tauri::webview::InvokeRequest {
            cmd: cmd.to_string(),
            callback: tauri::ipc::CallbackFn(0),
            error: tauri::ipc::CallbackFn(1),
            url: "http://tauri.localhost".parse().expect("static url"),
            body: tauri::ipc::InvokeBody::Json(payload),
            headers: Default::default(),
            invoke_key: INVOKE_KEY.to_string(),
        },
    );

    match result {
        Ok(response) => {
            let data = response
                .deserialize::<Value>()
                .unwrap_or(Value::Null);
            respond(request, 200, json!({ "ok": true, "data": data }));
        }
        Err(error) => respond(request, 200, json!({ "ok": false, "error": error })),
    }
}
