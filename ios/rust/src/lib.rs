//! iOS / iPadOS entry point for SoundCue.
//!
//! `main.m` calls [`soundcue_start`], which hands control to eframe/winit (it never returns).
//! The Objective-C shim (`App/Shim.m`) provides UIKit pieces egui does not have:
//! the Files document picker (import and export) and opening URLs.

use eframe::egui;
use soundcue_ui::platform::{Platform, PlatformResult};
use soundcue_ui::AudioApp;
use std::collections::VecDeque;
use std::ffi::{c_char, c_int, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

extern "C" {
    fn sc_ios_request_open(multi: c_int);
    fn sc_ios_request_export(path: *const c_char);
    fn sc_ios_open_url(url: *const c_char);
}

static RESULTS: Mutex<VecDeque<PlatformResult>> = Mutex::new(VecDeque::new());
static CTX: OnceLock<egui::Context> = OnceLock::new();

fn push(r: PlatformResult) {
    RESULTS.lock().unwrap().push_back(r);
    if let Some(ctx) = CTX.get() { ctx.request_repaint(); }
}

/// Called by the shim when the import picker finishes. `paths` are UTF-8 file paths
/// already copied into the app's Documents/Imported folder. `n == 0` means cancelled.
#[no_mangle]
pub unsafe extern "C" fn sc_ios_on_opened(paths: *const *const c_char, n: c_int) {
    if n <= 0 || paths.is_null() { push(PlatformResult::Cancelled); return; }
    let v = (0..n as usize)
        .filter_map(|i| { let p = *paths.add(i); (!p.is_null()).then(|| PathBuf::from(CStr::from_ptr(p).to_string_lossy().into_owned())) })
        .collect();
    push(PlatformResult::Opened(v));
}

fn home() -> PathBuf { std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(".")) }

struct IosPlatform;

impl Platform for IosPlatform {
    fn request_open(&mut self, multi: bool) { unsafe { sc_ios_request_open(multi as c_int) } }
    fn request_save(&mut self, suggested_name: &str, ext: &str) {
        // Write into the app container first; after_save then offers "Save to Files".
        let dir = home().join("Documents").join("Exports");
        let _ = std::fs::create_dir_all(&dir);
        let clean: String = suggested_name.chars().map(|c| if matches!(c, '/' | '\\' | ':') { '_' } else { c }).collect();
        let base = if clean.trim().is_empty() { "Untitled".to_string() } else { clean };
        let ext = ext.trim_start_matches('.');
        let file = if ext.is_empty() || base.to_lowercase().ends_with(&format!(".{}", ext.to_lowercase())) { base } else { format!("{base}.{ext}") };
        push(PlatformResult::SaveTo(dir.join(file)));
    }
    fn poll(&mut self) -> Option<PlatformResult> { RESULTS.lock().unwrap().pop_front() }
    fn data_dir(&self) -> PathBuf {
        let d = home().join("Library").join("Application Support").join("SoundCue");
        let _ = std::fs::create_dir_all(&d);
        d
    }
    fn open_url(&self, url: &str) {
        if let Ok(c) = CString::new(url) { unsafe { sc_ios_open_url(c.as_ptr()) } }
    }
    fn is_touch(&self) -> bool { true }
    fn after_save(&mut self, path: &Path) {
        if let Ok(c) = CString::new(path.to_string_lossy().as_bytes()) { unsafe { sc_ios_request_export(c.as_ptr()) } }
    }
}

#[no_mangle]
pub extern "C" fn soundcue_start() {
    let options = eframe::NativeOptions {
        renderer: eframe::Renderer::Wgpu,
        ..Default::default()
    };
    let r = eframe::run_native(
        "SoundCue",
        options,
        Box::new(|cc| {
            let _ = CTX.set(cc.egui_ctx.clone());
            Ok(Box::new(AudioApp::new(cc, Box::new(IosPlatform))))
        }),
    );
    if let Err(e) = r { eprintln!("SoundCue failed to start: {e}"); }
}
