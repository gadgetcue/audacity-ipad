//! Temporary stand-in for the real `soundcue-ui` crate (same public contract).
pub mod platform;

use eframe::egui;
use platform::{Platform, PlatformResult};
use std::sync::{atomic::{AtomicBool, Ordering}, Arc};

pub struct AudioApp {
    platform: Box<dyn Platform>,
    status: String,
    playing: Arc<AtomicBool>,
    stream: Option<cpal::Stream>,
    sel: Option<(f32, f32)>,
}

impl AudioApp {
    pub fn new(_cc: &eframe::CreationContext, platform: Box<dyn Platform>) -> Self {
        Self { platform, status: "Ready".into(), playing: Arc::new(AtomicBool::new(false)), stream: None, sel: None }
    }

    fn toggle_tone(&mut self) {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        if self.stream.is_some() {
            self.stream = None;
            self.playing.store(false, Ordering::Relaxed);
            self.status = "Stopped".into();
            return;
        }
        let host = cpal::default_host();
        let Some(dev) = host.default_output_device() else { self.status = "No output device".into(); return; };
        let cfg = match dev.default_output_config() { Ok(c) => c, Err(e) => { self.status = format!("Config error: {e}"); return; } };
        let sr = cfg.sample_rate() as f32;
        let ch = cfg.channels() as usize;
        let mut phase = 0f32;
        let res = dev.build_output_stream(
            cfg.config(),
            move |data: &mut [f32], _| {
                for frame in data.chunks_mut(ch) {
                    let v = (phase * std::f32::consts::TAU).sin() * 0.2;
                    phase = (phase + 440.0 / sr) % 1.0;
                    for s in frame.iter_mut() { *s = v; }
                }
            },
            |e| eprintln!("stream error {e}"),
            None,
        );
        match res {
            Ok(s) => { let _ = s.play(); self.stream = Some(s); self.playing.store(true, Ordering::Relaxed); self.status = format!("Playing 440 Hz at {sr} Hz"); }
            Err(e) => self.status = format!("Stream error: {e}"),
        }
    }
}

impl eframe::App for AudioApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        if let Some(r) = self.platform.poll() {
            self.status = match r {
                PlatformResult::Opened(p) => format!("Opened {} file(s): {:?}", p.len(), p.first()),
                PlatformResult::SaveTo(p) => { let _ = std::fs::write(&p, b"test"); self.platform.after_save(&p); format!("Saved {}", p.display()) }
                PlatformResult::Cancelled => "Cancelled".into(),
            };
        }
        egui::Panel::top("tb").show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.heading("SoundCue (iOS pipeline stub)");
                if ui.button(if self.stream.is_some() { "Stop" } else { "Play tone" }).clicked() { self.toggle_tone(); }
                if ui.button("Open…").clicked() { self.platform.request_open(true); }
                if ui.button("Export…").clicked() { self.platform.request_save("test", "wav"); }
            });
        });
        egui::Panel::bottom("sb").show(ui, |ui| { ui.label(&self.status); });
        egui::CentralPanel::default().show(ui, |ui| {
            let (rect, resp) = ui.allocate_exact_size(ui.available_size(), egui::Sense::click_and_drag());
            let p = ui.painter_at(rect);
            p.rect_filled(rect, 8.0, egui::Color32::from_rgb(30, 31, 35));
            if resp.drag_started() { if let Some(pos) = resp.interact_pointer_pos() { self.sel = Some((pos.x, pos.x)); } }
            if resp.dragged() { if let (Some(pos), Some(s)) = (resp.interact_pointer_pos(), self.sel.as_mut()) { s.1 = pos.x; } }
            if let Some((a, b)) = self.sel {
                let r = egui::Rect::from_x_y_ranges(a.min(b)..=a.max(b), rect.y_range());
                p.rect_filled(r, 0.0, egui::Color32::from_rgba_unmultiplied(64, 156, 255, 60));
            }
            let n = rect.width() as usize;
            let mid = rect.center().y;
            let pts: Vec<egui::Pos2> = (0..n).map(|i| {
                let t = i as f32 / 40.0;
                egui::pos2(rect.left() + i as f32, mid + (t.sin() * (t * 0.13).cos()) * rect.height() * 0.35)
            }).collect();
            p.add(egui::Shape::line(pts, egui::Stroke::new(1.5, egui::Color32::from_rgb(64, 156, 255))));
        });
    }
}
