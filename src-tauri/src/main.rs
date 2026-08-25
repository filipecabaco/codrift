// Prevents additional console window on Windows in release, DO NOT REMOVE!!
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use tauri_plugin_shell::process::CommandEvent;
use tauri_plugin_shell::ShellExt;
use tauri::Manager;
use tauri::menu::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu};

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const HOST: &str = "localhost";
const PORT: &str = "43117";

struct AppState {
    sidecar_child: Mutex<Option<SidecarProcess>>,
}

struct SidecarProcess {
    child: Option<tauri_plugin_shell::process::CommandChild>,
    pid: Option<u32>,
}

impl Drop for SidecarProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.take() {
            let _ = child.kill();
        }
    }
}

fn kill_sidecar(app: &tauri::AppHandle) {
    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            if let Some(mut process) = guard.take() {
                // Try graceful shutdown first with SIGTERM
                if let Some(pid) = process.pid {
                    println!("Attempting graceful shutdown of sidecar (PID: {})...", pid);

                    // Send SIGTERM for graceful shutdown
                    #[cfg(unix)]
                    {
                        use std::process::Command;
                        let _ = Command::new("kill")
                            .args(["-TERM", &pid.to_string()])
                            .output();

                        // Wait up to 2 seconds for graceful shutdown
                        let timeout = Duration::from_millis(2000);
                        let start = std::time::Instant::now();

                        while start.elapsed() < timeout {
                            // Check if process is still running
                            let status = Command::new("kill")
                                .args(["-0", &pid.to_string()])
                                .output();

                            if let Ok(output) = status {
                                if !output.status.success() {
                                    println!("Sidecar shut down gracefully");
                                    return;
                                }
                            }

                            std::thread::sleep(Duration::from_millis(100));
                        }

                        println!("Graceful shutdown timeout, forcing kill...");
                    }

                    #[cfg(windows)]
                    {
                        // On Windows, wait a bit for graceful shutdown
                        std::thread::sleep(Duration::from_millis(2000));
                    }
                }

                // Fallback to SIGKILL if graceful shutdown didn't work
                if let Some(child) = process.child.take() {
                    println!("Sending SIGKILL to sidecar...");
                    let _ = child.kill();
                }
            }
        }
    }
}

// Lets the page quit the app once its own confirm dialog has been accepted.
// Registered below via `invoke_handler`; without that registration the frontend's
// `invoke("quit_app")` rejects with "command not found" and Quit silently does
// nothing — which is exactly what shipped in 0.0.2.
#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    kill_sidecar(&app);
    std::process::exit(0);
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![quit_app])
        .plugin(tauri_plugin_single_instance::init(|_app, _args, _cwd| {
            // Focus the main window when a second instance is launched
        }))
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_log::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .manage(AppState {
            sidecar_child: Mutex::new(None),
        })
        .menu(build_menu)
        .setup(|app| {
            // Size the window to 60% of the current monitor and center it.
            if let Some(window) = app.get_webview_window("main") {
                if let Ok(Some(monitor)) = window.current_monitor() {
                    let screen = monitor.size();
                    let width = (screen.width as f64 * 0.6).round() as u32;
                    let height = (screen.height as f64 * 0.6).round() as u32;
                    let _ = window.set_size(tauri::PhysicalSize::new(width, height));
                    let _ = window.center();
                }
            }

            // Identity for this launch. The sidecar echoes it from /api/health, so
            // the shell can tell *its own* backend apart from anything else already
            // listening on the port (e.g. a sidecar left over from a previous
            // version, which is what made 0.0.2 open on a bare "not found" page).
            let token = instance_token();
            let died = Arc::new(AtomicBool::new(false));

            start_server(app.handle(), &token, died.clone());

            match await_our_server(&token, &died) {
                Ok(()) => start_heartbeat(),
                Err(reason) => show_startup_error(app.handle(), &reason),
            }
            Ok(())
        })
        // Intercept menu events (especially CMD+Q on macOS)
        .on_menu_event(|app, event| {
            let id = event.id().as_ref().to_string();
            println!("Menu event received: {:?}", id);

            if id == "quit" {
                // Ask the page first so its "N agents still running" confirm gets a
                // say. The page answers by invoking `quit_app`. If the webview is
                // gone (or eval fails) there is nobody to ask — quit immediately,
                // so a dead page can never make Quit a no-op.
                if !dispatch_to_page(app, QUIT_REQUESTED_EVENT, None) {
                    println!("No webview to confirm with — quitting directly");
                    kill_sidecar(app);
                    std::process::exit(0);
                }
                return;
            }

            // Everything else is the page's to run. A menu item that cannot be
            // delivered is a dead menu item, so say so in the log rather than
            // letting the click vanish.
            if !dispatch_to_page(app, MENU_EVENT, Some(&id)) {
                eprintln!("Menu command {:?} had no webview to run in", id);
            }
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { .. } = event {
                // Kill the sidecar when the window closes
                kill_sidecar(&window.app_handle());
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app_handle, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                // Kill the sidecar when the app is exiting (fallback for non-menu exits)
                println!("ExitRequested event received, shutting down...");
                kill_sidecar(app_handle);
                api.prevent_exit(); // Prevent exit until we've cleaned up
                // Allow exit after cleanup
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(500));
                    std::process::exit(0);
                });
            }
        });
}

// ── Menu ─────────────────────────────────────────────────────────────────────

/// Asks the page whether it is willing to quit, rather than quitting outright.
const QUIT_REQUESTED_EVENT: &str = "codrift:quit-requested";

/// Carries a menu command id to the page, which runs it. See `build_menu`.
const MENU_EVENT: &str = "codrift:menu";

/// Fires a CustomEvent on the page's `window`, returning whether there was a
/// page to fire it at.
fn dispatch_to_page(app: &tauri::AppHandle, event: &str, detail: Option<&str>) -> bool {
    let detail = match detail {
        Some(value) => serde_json::to_string(value).unwrap_or_else(|_| "null".to_string()),
        None => "null".to_string(),
    };

    app.get_webview_window("main")
        .map(|window| {
            window
                .eval(&format!(
                    "window.dispatchEvent(new CustomEvent({}, {{detail: {}}}))",
                    serde_json::to_string(event).unwrap_or_else(|_| "\"\"".to_string()),
                    detail
                ))
                .is_ok()
        })
        .unwrap_or(false)
}

/// One menu item that is nothing but a named command for the page to run.
///
/// The shell deliberately implements none of these. `App.svelte` already routes
/// every one of them through `runAction`, and a second implementation in Rust
/// would only give the menu and the keyboard something to disagree about — so
/// the id here *is* the command name the page dispatches on.
fn command<R: tauri::Runtime>(
    handle: &tauri::AppHandle<R>,
    id: &str,
    label: &str,
    accelerator: Option<&str>,
) -> tauri::Result<MenuItem<R>> {
    MenuItem::with_id(handle, id, label, true, accelerator)
}

/// How the sidebar orders initiatives — a nested submenu because these four are
/// one choice, not four independent commands.
fn sort_menu<R: tauri::Runtime>(handle: &tauri::AppHandle<R>) -> tauri::Result<Submenu<R>> {
    Submenu::with_items(
        handle,
        "Sort Initiatives By",
        true,
        &[
            &command(handle, "sort_recent", "Recently Active", None)?,
            &command(handle, "sort_created", "Date Created", None)?,
            &command(handle, "sort_name", "Name", None)?,
            &command(handle, "sort_status", "Status", None)?,
        ],
    )
}

/// The application menu.
///
/// Tauri v2 installs no default menu at all, which is why this used to be one
/// Quit item and an Edit submenu — a menu bar that told a first-time user
/// nothing about what the app could do, and left every command discoverable only
/// by already knowing the keymap.
///
/// Two rules shape what is here:
///
/// 1. **Quit stays a custom item.** The *predefined* Quit terminates natively
///    and bypasses `on_menu_event`, orphaning the sidecar. The custom one (id
///    `quit`) routes through the handler, which asks the page first and then
///    kills the backend.
///
/// 2. **Accelerators must not shadow the in-page keymap.** A menu accelerator is
///    swallowed by the menu and never reaches the webview, so anything bound
///    here is taken away from the page. The bare-letter bindings (`n`, `s`, `r`,
///    `1`/`2`/`3` …) are untouched because they carry no modifier; `⌘D`, `⇧⌘D`
///    and `⌘⌃=` appear here on purpose, forwarding to the same handlers the page
///    would have run, so the split commands finally have a visible name. `⌘1`…`⌘9`
///    are deliberately *absent*: the page uses them to jump between panes.
fn build_menu<R: tauri::Runtime>(handle: &tauri::AppHandle<R>) -> tauri::Result<Menu<R>> {
    let sep = || PredefinedMenuItem::separator(handle);

    let app_menu = Submenu::with_items(
        handle,
        "Codrift",
        true,
        &[
            &PredefinedMenuItem::about(handle, Some("About Codrift"), Some(AboutMetadata::default()))?,
            &sep()?,
            &command(handle, "settings", "Settings…", Some("CmdOrCtrl+,"))?,
            // Direct jumps to a section of that same window. Only Settings gets
            // ⌘, — it is the door, and the page binds the same key to the same
            // action for the dev server, where there is no menu to swallow it.
            &command(handle, "appearance", "Appearance…", None)?,
            &command(handle, "agent_profiles", "Launch Profiles…", Some("Shift+CmdOrCtrl+P"))?,
            &command(handle, "integrations", "Integrations…", Some("Shift+CmdOrCtrl+I"))?,
            &command(handle, "setup", "Run Setup…", None)?,
            &sep()?,
            &command(handle, "quit", "Quit Codrift", Some("CmdOrCtrl+Q"))?,
        ],
    )?;

    let initiative_menu = Submenu::with_items(
        handle,
        "Initiative",
        true,
        &[
            &command(handle, "new_initiative", "New Initiative…", Some("CmdOrCtrl+N"))?,
            &command(handle, "new_scratchpad", "New Scratchpad", Some("Shift+CmdOrCtrl+N"))?,
            &command(handle, "promote_initiative", "Promote Scratchpad…", None)?,
            &sep()?,
            &command(handle, "add_dir", "Add Directory…", Some("Shift+CmdOrCtrl+A"))?,
            &sep()?,
            &command(handle, "initiative_agent", "Change Agent…", None)?,
            &command(handle, "branch_initiative", "Branch Git Directories", Some("Shift+CmdOrCtrl+B"))?,
            &command(handle, "sync_context", "Sync Imported Context", None)?,
            &sep()?,
            &command(handle, "status_next", "Advance Status", Some("CmdOrCtrl+]"))?,
            &command(handle, "status_prev", "Roll Back Status", Some("CmdOrCtrl+["))?,
            &sep()?,
            // Deliberately vague: this acts on whatever the cursor is on, which
            // may be an initiative, a directory or a running agent.
            &command(handle, "delete", "Delete or Stop Selection", Some("CmdOrCtrl+Backspace"))?,
        ],
    )?;

    let agent_menu = Submenu::with_items(
        handle,
        "Agent",
        true,
        &[
            &command(handle, "start_agent", "Start Agent", Some("CmdOrCtrl+Return"))?,
            &command(handle, "start_terminal", "Open Terminal", Some("CmdOrCtrl+T"))?,
            &sep()?,
            &command(handle, "start_orchestration", "Start Orchestration…", Some("Shift+CmdOrCtrl+O"))?,
            &sep()?,
            &command(handle, "focus_next_waiting", "Go to Next Waiting Agent", Some("CmdOrCtrl+G"))?,
        ],
    )?;

    let view_menu = Submenu::with_items(
        handle,
        "View",
        true,
        &[
            &command(handle, "context_mode", "Context", None)?,
            &command(handle, "diff_mode", "Diff", None)?,
            &command(handle, "tree_mode", "Files", None)?,
            &sep()?,
            &command(handle, "toggle_sidebar", "Toggle Sidebar", Some("CmdOrCtrl+B"))?,
            &sort_menu(handle)?,
            &command(handle, "refresh", "Refresh", Some("CmdOrCtrl+R"))?,
            &sep()?,
            &command(handle, "split_vertical", "Split Right", Some("CmdOrCtrl+D"))?,
            &command(handle, "split_horizontal", "Split Down", Some("Shift+CmdOrCtrl+D"))?,
            &command(handle, "balance_split", "Balance Panes", Some("CmdOrCtrl+Control+="))?,
            &command(handle, "close_pane", "Close Pane", Some("Shift+CmdOrCtrl+W"))?,
            &sep()?,
            &command(handle, "palette", "Command Palette", Some("CmdOrCtrl+K"))?,
        ],
    )?;

    let edit_menu = Submenu::with_items(
        handle,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(handle, None)?,
            &PredefinedMenuItem::redo(handle, None)?,
            &sep()?,
            &PredefinedMenuItem::cut(handle, None)?,
            &PredefinedMenuItem::copy(handle, None)?,
            &PredefinedMenuItem::paste(handle, None)?,
            &PredefinedMenuItem::select_all(handle, None)?,
        ],
    )?;

    let window_menu = Submenu::with_items(
        handle,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(handle, None)?,
            &PredefinedMenuItem::maximize(handle, None)?,
            &sep()?,
            &PredefinedMenuItem::close_window(handle, None)?,
        ],
    )?;

    let help_menu = Submenu::with_items(
        handle,
        "Help",
        true,
        &[
            &command(handle, "help_docs", "Codrift Documentation", None)?,
            &command(handle, "help_keys", "Keyboard Shortcuts", None)?,
            &sep()?,
            &command(handle, "help_issue", "Report an Issue", None)?,
        ],
    )?;

    Menu::with_items(
        handle,
        &[
            &app_menu,
            &initiative_menu,
            &agent_menu,
            &view_menu,
            &edit_menu,
            &window_menu,
            &help_menu,
        ],
    )
}

fn start_server(app: &tauri::AppHandle, token: &str, died: Arc<AtomicBool>) {
    let sidecar_command = app
        .shell()
        .sidecar("desktop")
        .expect("failed to setup `desktop` sidecar")
        .env("CODRIFT_INSTANCE_TOKEN", token);

    let (mut rx, child) = sidecar_command
        .spawn()
        .expect("Failed to spawn desktop sidecar");

    // Get the PID for graceful shutdown
    let pid = child.pid();
    println!("Sidecar process started with PID: {}", pid);

    // Store the child process handle so we can kill it on exit
    if let Some(state) = app.try_state::<AppState>() {
        if let Ok(mut guard) = state.sidecar_child.lock() {
            *guard = Some(SidecarProcess {
                child: Some(child),
                pid: Some(pid),
            });
        }
    }

    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(line_bytes) | CommandEvent::Stderr(line_bytes) => {
                    println!("{}", String::from_utf8_lossy(&line_bytes));
                }
                // The backend exited on its own — almost always a failure to bind
                // :43117. Record it so the startup wait stops immediately with a
                // real reason instead of spinning until the timeout.
                CommandEvent::Terminated(payload) => {
                    println!("Sidecar terminated: {:?}", payload);
                    died.store(true, Ordering::SeqCst);
                }
                _ => {}
            }
        }
    });
}

// Unique per launch, and cheap: no RNG crate, and it only has to distinguish this
// process from another Codrift on the same machine.
fn instance_token() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}", std::process::id(), nanos)
}

/// Block until the port is served by the sidecar *we* just spawned.
///
/// The old version broke out of its loop as soon as anything accepted a TCP
/// connection on :43117. A stale sidecar from a previous version answers that
/// check happily, so the window would load its pages — and because Burrito
/// deletes the previous version's unpacked release on upgrade, that stale server
/// can no longer read `priv/static` and answers `/index.html` with a bare 404
/// body. Matching on the instance token makes adopting a stranger impossible.
fn await_our_server(token: &str, died: &Arc<AtomicBool>) -> Result<(), String> {
    let addr = format!("{}:{}", HOST, PORT);
    println!("Waiting for the Codrift backend on {}...", addr);

    let deadline = std::time::Instant::now() + Duration::from_secs(30);
    let mut saw_foreign_server = false;

    while std::time::Instant::now() < deadline {
        if died.load(Ordering::SeqCst) {
            return Err(port_conflict_message(saw_foreign_server));
        }

        match health_token(&addr) {
            Some(found) if found == token => return Ok(()),
            Some(_) => saw_foreign_server = true,
            None => {}
        }

        std::thread::sleep(Duration::from_millis(200));
    }

    Err(port_conflict_message(saw_foreign_server))
}

fn port_conflict_message(saw_foreign_server: bool) -> String {
    if saw_foreign_server {
        format!(
            "Another Codrift backend is already using port {PORT}, so this window has no server \
             of its own. It is usually a sidecar left running by an older version.\n\n\
             Quit the other Codrift, or run this in a terminal, then reopen Codrift:\n\n\
             pkill -f 'burrito/desktop_.*/erts-.*/bin/beam.smp'"
        )
    } else {
        format!(
            "The Codrift backend did not start on port {PORT}.\n\n\
             Check the log at $TMPDIR/codrift_desktop.log for the reason."
        )
    }
}

/// One-shot `GET /api/health`, returning the `instance` field the sidecar echoes.
/// Hand-rolled so the shell needs no HTTP crate for a single request.
fn health_token(addr: &str) -> Option<String> {
    let mut stream = std::net::TcpStream::connect(addr).ok()?;
    stream.set_read_timeout(Some(Duration::from_millis(1000))).ok()?;
    stream.set_write_timeout(Some(Duration::from_millis(1000))).ok()?;
    stream
        .write_all(
            format!("GET /api/health HTTP/1.0\r\nHost: {HOST}\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .ok()?;

    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    parse_instance(&response)
}

/// Body is `{"ok":true,"instance":"<token>"}` — pull the field out without
/// pulling in a JSON parser for one string.
fn parse_instance(response: &str) -> Option<String> {
    let marker = "\"instance\":\"";
    let start = response.find(marker)? + marker.len();
    let rest = &response[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// Replace whatever the window loaded with a readable explanation. Without this
/// a failed startup shows the other server's 404 body, or a blank page — no clue
/// what went wrong.
fn show_startup_error(app: &tauri::AppHandle, reason: &str) {
    eprintln!("Codrift failed to start: {}", reason);

    let Some(window) = app.get_webview_window("main") else {
        return;
    };

    let script = format!(
        r#"
        document.title = "Codrift — can't start";
        document.body.innerHTML = "";
        document.body.style.cssText =
          "margin:0;padding:48px;background:#16181d;color:#e6e6e6;" +
          "font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap";
        document.body.textContent = {};
        "#,
        serde_json::to_string(&format!("Codrift can't start\n\n{reason}"))
            .unwrap_or_else(|_| "\"Codrift can't start\"".to_string())
    );

    // Re-applied for a few seconds: the window is loading its URL concurrently,
    // and whatever finishes last wins. Without this the error can be wiped by the
    // very page (a stale server's 404) it is meant to explain.
    std::thread::spawn(move || {
        for _ in 0..12 {
            let _ = window.eval(&script);
            std::thread::sleep(Duration::from_millis(250));
        }
    });
}

fn start_heartbeat() {
    println!("Starting heartbeat to Phoenix sidecar...");

    std::thread::spawn(|| {
        use std::io::Write;

        let socket_path = std::env::temp_dir().join("tauri_heartbeat_codrift.sock");
        let interval = Duration::from_millis(100);

        #[cfg(unix)]
        {
            use std::os::unix::net::UnixStream;

            // Outer loop: (re)establish the connection. The sidecar's listener can
            // come up late (slow boot) or be recreated (its manager restarting), so
            // a dropped connection must reconnect rather than end the heartbeat —
            // otherwise the backend would see the heartbeat stop and shut itself down.
            loop {
                let mut stream = loop {
                    match UnixStream::connect(&socket_path) {
                        Ok(s) => break s,
                        Err(_) => std::thread::sleep(Duration::from_millis(100)),
                    }
                };

                println!("Connected to heartbeat socket");

                // Send heartbeats until the connection drops, then reconnect.
                while stream.write_all(b"h").is_ok() {
                    std::thread::sleep(interval);
                }

                println!("Heartbeat connection lost, reconnecting...");
            }
        }

        #[cfg(windows)]
        {
            // Windows: use named pipe or TCP fallback for heartbeat
            // TODO: Implement Windows named pipe heartbeat
            println!("Heartbeat not yet supported on Windows");
        }
    });
}

#[cfg(test)]
mod tests {
    use super::parse_instance;

    // The exact shape Bandit returns for GET /api/health, headers included.
    const RESPONSE: &str = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\r\n\
{\"ok\":true,\"instance\":\"1f4c-18b2e9c0a11\"}";

    #[test]
    fn reads_the_instance_token_from_a_real_response() {
        assert_eq!(parse_instance(RESPONSE).as_deref(), Some("1f4c-18b2e9c0a11"));
    }

    #[test]
    fn reports_none_when_the_field_is_absent() {
        // A pre-handshake sidecar, or something else entirely on the port. Either
        // way it is not ours, so startup must not adopt it.
        assert_eq!(parse_instance("HTTP/1.1 200 OK\r\n\r\n{\"ok\":true}"), None);
        assert_eq!(parse_instance("HTTP/1.1 404 Not Found\r\n\r\nnot found"), None);
    }

    #[test]
    fn reads_an_empty_token_when_launched_without_one() {
        let response = "HTTP/1.1 200 OK\r\n\r\n{\"ok\":true,\"instance\":\"\"}";
        assert_eq!(parse_instance(response).as_deref(), Some(""));
    }
}
