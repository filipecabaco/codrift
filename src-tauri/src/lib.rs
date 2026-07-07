use tauri::{Manager, PhysicalSize};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  tauri::Builder::default()
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
