//! A desktop [`agent_core::ComputerBackend`] for **Windows, macOS, and Linux** in one impl, via
//! `xcap` (capture) + `enigo` (input). Coordinates arrive in model space; we scale them to the
//! platform's own display metrics (`enigo::Mouse::main_display`), which handles Windows DPI and
//! macOS points-vs-pixels uniformly. The same logic drives every desktop OS.

use agent_core::{Action, AgentError, ComputerBackend, Result, Screenshot};
use async_trait::async_trait;
use base64::Engine as _;
use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use xcap::Monitor;

fn be<E: std::fmt::Display>(e: E) -> AgentError {
    AgentError::Backend(e.to_string())
}

/// Fit capture pixels into an XGA-ish box: small enough to upload fast, large enough to click well.
fn model_dims(cw: u32, ch: u32) -> (u32, u32) {
    let f = (1024.0 / cw as f64).min(768.0 / ch as f64).min(1.0);
    (((cw as f64 * f).round() as u32).max(1), ((ch as f64 * f).round() as u32).max(1))
}

fn primary() -> Result<Monitor> {
    let monitors = Monitor::all().map_err(be)?;
    let mut found = None;
    for m in monitors {
        if m.is_primary().unwrap_or(false) {
            return Ok(m);
        }
        if found.is_none() {
            found = Some(m);
        }
    }
    found.ok_or_else(|| AgentError::Backend("no monitor found".into()))
}

pub struct DesktopBackend {
    model: (u32, u32),
}

impl DesktopBackend {
    /// Measure the screen once so `model_size()` is known before the first capture.
    pub fn new() -> Result<Self> {
        let img = primary()?.capture_image().map_err(be)?;
        Ok(Self { model: model_dims(img.width(), img.height()) })
    }

    fn map(&self, c: &[i32; 2], dw: i32, dh: i32) -> (i32, i32) {
        let (mw, mh) = self.model;
        (
            (c[0] as f64 * dw as f64 / mw as f64).round() as i32,
            (c[1] as f64 * dh as f64 / mh as f64).round() as i32,
        )
    }

    fn do_action(&self, action: &Action) -> Result<Option<String>> {
        let mut e = Enigo::new(&Settings::default()).map_err(be)?;
        let (dw, dh) = e.main_display().map_err(be)?;

        match action {
            Action::Screenshot => {}
            Action::Wait { duration } => {
                std::thread::sleep(std::time::Duration::from_secs_f64(duration.min(3.0)))
            }
            Action::CursorPosition => {
                let (x, y) = e.location().map_err(be)?;
                let (mw, mh) = self.model;
                let mx = (x as f64 * mw as f64 / dw as f64).round() as i32;
                let my = (y as f64 * mh as f64 / dh as f64).round() as i32;
                return Ok(Some(format!("cursor at [{mx}, {my}]")));
            }
            Action::MouseMove { coordinate } => {
                let (x, y) = self.map(coordinate, dw, dh);
                e.move_mouse(x, y, Coordinate::Abs).map_err(be)?;
            }
            Action::LeftClick { coordinate, text } => {
                self.click(&mut e, coordinate, dw, dh, Button::Left, 1, text)?
            }
            Action::RightClick { coordinate, text } => {
                self.click(&mut e, coordinate, dw, dh, Button::Right, 1, text)?
            }
            Action::MiddleClick { coordinate, text } => {
                self.click(&mut e, coordinate, dw, dh, Button::Middle, 1, text)?
            }
            Action::DoubleClick { coordinate, text } => {
                self.click(&mut e, coordinate, dw, dh, Button::Left, 2, text)?
            }
            Action::TripleClick { coordinate, text } => {
                self.click(&mut e, coordinate, dw, dh, Button::Left, 3, text)?
            }
            Action::LeftClickDrag { start_coordinate, coordinate } => {
                let (sx, sy) = self.map(start_coordinate, dw, dh);
                let (ex, ey) = self.map(coordinate, dw, dh);
                e.move_mouse(sx, sy, Coordinate::Abs).map_err(be)?;
                e.button(Button::Left, Direction::Press).map_err(be)?;
                e.move_mouse(ex, ey, Coordinate::Abs).map_err(be)?;
                e.button(Button::Left, Direction::Release).map_err(be)?;
            }
            Action::Scroll { coordinate, scroll_direction, scroll_amount, .. } => {
                let (x, y) = self.map(coordinate, dw, dh);
                e.move_mouse(x, y, Coordinate::Abs).map_err(be)?;
                let n = *scroll_amount;
                let (len, axis) = match scroll_direction.as_str() {
                    "up" => (-n, Axis::Vertical),
                    "down" => (n, Axis::Vertical),
                    "left" => (-n, Axis::Horizontal),
                    _ => (n, Axis::Horizontal),
                };
                e.scroll(len, axis).map_err(be)?;
            }
            Action::Key { text } => {
                let (mods, main) = parse_combo(text);
                press_mods(&mut e, &mods)?;
                let r = main.map(|k| e.key(k, Direction::Click).map_err(be)).transpose();
                release_mods(&mut e, &mods);
                r?;
            }
            Action::HoldKey { text, duration } => {
                let (_mods, main) = parse_combo(text);
                if let Some(k) = main {
                    e.key(k, Direction::Press).map_err(be)?;
                    std::thread::sleep(std::time::Duration::from_secs_f64(duration.min(5.0)));
                    e.key(k, Direction::Release).map_err(be)?;
                }
            }
            Action::Type { text } => e.text(text).map_err(be)?,
        }

        // Focus-changing actions settle before the loop's verification capture.
        if action.needs_settle() {
            std::thread::sleep(std::time::Duration::from_millis(220));
        }
        Ok(None)
    }

    #[allow(clippy::too_many_arguments)]
    fn click(
        &self,
        e: &mut Enigo,
        coordinate: &[i32; 2],
        dw: i32,
        dh: i32,
        btn: Button,
        times: u8,
        text: &Option<String>,
    ) -> Result<()> {
        let (x, y) = self.map(coordinate, dw, dh);
        let mods = text.as_deref().map(|s| parse_combo(s).0).unwrap_or_default();
        e.move_mouse(x, y, Coordinate::Abs).map_err(be)?;
        press_mods(e, &mods)?;
        let mut res = Ok(());
        for _ in 0..times.max(1) {
            if let Err(err) = e.button(btn, Direction::Click).map_err(be) {
                res = Err(err);
                break;
            }
        }
        release_mods(e, &mods);
        res
    }
}

fn press_mods(e: &mut Enigo, mods: &[Key]) -> Result<()> {
    for m in mods {
        e.key(*m, Direction::Press).map_err(be)?;
    }
    Ok(())
}

fn release_mods(e: &mut Enigo, mods: &[Key]) {
    for m in mods.iter().rev() {
        let _ = e.key(*m, Direction::Release);
    }
}

fn modifier(token: &str) -> Option<Key> {
    match token {
        "cmd" | "command" | "super" | "meta" | "win" => Some(Key::Meta),
        "ctrl" | "control" => Some(Key::Control),
        "alt" | "option" | "opt" => Some(Key::Alt),
        "shift" => Some(Key::Shift),
        _ => None,
    }
}

fn named_key(token: &str) -> Option<Key> {
    Some(match token {
        "return" | "enter" => Key::Return,
        "tab" => Key::Tab,
        "space" => Key::Space,
        "backspace" => Key::Backspace,
        "delete" => Key::Delete,
        "escape" | "esc" => Key::Escape,
        "up" => Key::UpArrow,
        "down" => Key::DownArrow,
        "left" => Key::LeftArrow,
        "right" => Key::RightArrow,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" | "page_up" => Key::PageUp,
        "pagedown" | "page_down" => Key::PageDown,
        t if t.chars().count() == 1 => Key::Unicode(t.chars().next().unwrap()),
        _ => return None,
    })
}

/// Split "cmd+shift+s" → (modifiers, main key).
fn parse_combo(text: &str) -> (Vec<Key>, Option<Key>) {
    let mut mods = Vec::new();
    let mut main = None;
    for part in text.to_lowercase().split('+').map(str::trim).filter(|p| !p.is_empty()) {
        match modifier(part) {
            Some(m) => mods.push(m),
            None => main = named_key(part),
        }
    }
    (mods, main)
}

#[async_trait]
impl ComputerBackend for DesktopBackend {
    async fn capture(&self) -> Result<Screenshot> {
        let (mw, mh) = self.model;
        let rgba = primary()?.capture_image().map_err(be)?;
        let resized = image::imageops::resize(&rgba, mw, mh, image::imageops::FilterType::Triangle);
        let rgb = image::DynamicImage::ImageRgba8(resized).to_rgb8();
        let mut buf = std::io::Cursor::new(Vec::new());
        image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 50)
            .encode_image(&rgb)
            .map_err(be)?;
        Ok(Screenshot {
            data_base64: base64::engine::general_purpose::STANDARD.encode(buf.into_inner()),
            media_type: "image/jpeg".into(),
            width: mw,
            height: mh,
        })
    }

    async fn execute(&self, action: &Action) -> Result<Option<String>> {
        self.do_action(action)
    }

    fn model_size(&self) -> (u32, u32) {
        self.model
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combo_parsing_splits_modifiers_from_the_main_key() {
        let (mods, main) = parse_combo("cmd+shift+s");
        assert_eq!(mods.len(), 2);
        assert!(matches!(main, Some(Key::Unicode('s'))));

        let (mods, main) = parse_combo("ctrl+Return");
        assert_eq!(mods.len(), 1);
        assert!(matches!(main, Some(Key::Return)));
    }

    #[test]
    fn model_dims_fit_inside_the_box_and_keep_aspect() {
        let (w, h) = model_dims(3420, 2224);
        assert!(w <= 1024 && h <= 768);
        let ar_in = 3420.0 / 2224.0;
        let ar_out = w as f64 / h as f64;
        assert!((ar_in - ar_out).abs() < 0.02);
    }
}

#[cfg(test)]
mod live {
    use super::*;
    /// Live check on the host: the same capture path Windows/Linux run. Ignored by default.
    #[test]
    #[ignore]
    fn captures_this_screen() {
        let b = DesktopBackend::new().expect("backend");
        let (w, h) = b.model_size();
        let shot = pollster::block_on(b.capture()).expect("capture");
        println!("model {w}x{h} · jpeg base64 bytes: {}", shot.data_base64.len());
        assert!(shot.data_base64.len() > 1000);
        assert_eq!(shot.media_type, "image/jpeg");
    }
}
