use tauri::menu::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{Manager, PhysicalSize};

const QUIT_ID: &str = "codrift-quit";

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
  app.exit(0);
}

fn build_menu(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
  let quit = MenuItem::with_id(app, QUIT_ID, "Quit Codrift", true, Some("CmdOrCtrl+Q"))?;

  let app_menu = Submenu::with_items(
    app,
    "Codrift",
    true,
    &[
      &PredefinedMenuItem::about(app, None, Some(AboutMetadata::default()))?,
      &PredefinedMenuItem::separator(app)?,
      &PredefinedMenuItem::hide(app, None)?,
      &PredefinedMenuItem::hide_others(app, None)?,
      &PredefinedMenuItem::show_all(app, None)?,
      &PredefinedMenuItem::separator(app)?,
      &quit,
    ],
  )?;

  let edit_menu = Submenu::with_items(
    app,
    "Edit",
    true,
    &[
      &PredefinedMenuItem::undo(app, None)?,
      &PredefinedMenuItem::redo(app, None)?,
      &PredefinedMenuItem::separator(app)?,
      &PredefinedMenuItem::cut(app, None)?,
      &PredefinedMenuItem::copy(app, None)?,
      &PredefinedMenuItem::paste(app, None)?,
      &PredefinedMenuItem::select_all(app, None)?,
    ],
  )?;

  let window_menu = Submenu::with_items(
    app,
    "Window",
    true,
    &[
      &PredefinedMenuItem::minimize(app, None)?,
      &PredefinedMenuItem::maximize(app, None)?,
      &PredefinedMenuItem::separator(app)?,
      &PredefinedMenuItem::close_window(app, None)?,
    ],
  )?;

  Menu::with_items(app, &[&app_menu, &edit_menu, &window_menu])
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
    .invoke_handler(tauri::generate_handler![quit_app])
    .menu(build_menu)
    .on_menu_event(|app, event| {
      if event.id() == QUIT_ID {
        if let Some(window) = app.get_webview_window("main") {
          let _ = window.eval(
            "window.dispatchEvent(new CustomEvent('codrift:quit-requested'))",
          );
        }
      }
    })
    .setup(|app| {
      if cfg!(debug_assertions) {
        app.handle().plugin(
          tauri_plugin_log::Builder::default()
            .level(log::LevelFilter::Info)
            .build(),
        )?;
      }

      // Size the main window to 80% of the primary monitor and center it, so
      // Codrift launches as a roomy — but not fullscreen — workspace regardless
      // of display size. Best-effort: if the monitor can't be read we keep the
      // config's fallback width/height.
      if let Some(window) = app.get_webview_window("main") {
        if let Ok(Some(monitor)) = window.primary_monitor() {
          let size = monitor.size();
          let target = PhysicalSize::new(
            (size.width as f64 * 0.8) as u32,
            (size.height as f64 * 0.8) as u32,
          );
          let _ = window.set_size(target);
          let _ = window.center();
        }
      }

      Ok(())
    })
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
