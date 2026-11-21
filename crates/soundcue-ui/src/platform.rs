use std::path::{Path, PathBuf};

pub enum PlatformResult { Opened(Vec<PathBuf>), SaveTo(PathBuf), Cancelled }

pub trait Platform {
    fn request_open(&mut self, multi: bool);
    fn request_save(&mut self, suggested_name: &str, ext: &str);
    fn poll(&mut self) -> Option<PlatformResult>;
    fn data_dir(&self) -> PathBuf;
    fn open_url(&self, url: &str);
    fn is_touch(&self) -> bool { false }
    fn on_theme_changed(&self, _toolbar_rgb: [u8; 3], _text_rgb: [u8; 3]) {}
    fn after_save(&mut self, _path: &Path) {}
}
