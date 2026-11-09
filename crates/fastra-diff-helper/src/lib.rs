//! Plattformunabhängiger Aufrufvertrag; Linux verwendet den lokalen Sitzungsbus.
use serde::{Deserialize, Serialize};
use std::{fs::OpenOptions, os::unix::fs::OpenOptionsExt, path::Path, time::SystemTime};
#[cfg(target_os = "linux")]
pub const BUS: &str = fastra_io::local_control::transport::SYSTEM_APPLICATION_ID;
#[cfg(not(target_os = "linux"))]
pub const BUS: &str = "org.fastra.Fastra.Development";
#[cfg(target_os = "linux")]
pub const NATIVE_BUS: &str = fastra_io::local_control::transport::NATIVE_APPLICATION_ID;
pub fn bus() -> Result<&'static str, i32> {
    #[cfg(target_os = "linux")]
    {
        fastra_io::local_control::transport::application_id().map_err(|_| 6)
    }
    #[cfg(not(target_os = "linux"))]
    {
        Ok(BUS)
    }
}
pub const PATH: &str = "/org/fastra/Fastra/Development/Diff";
pub const INTERFACE: &str = "org.fastra.Diff1";
pub const MAX_MESSAGE: usize = 65_536;
pub const CAPABILITIES: &str = r#"{"protocol":1,"fileDiff":true,"readOnly":true,"focusDiff":true,"labels":true,"existingInstanceIpc":true}"#;
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
pub fn local_bus_address(address: &str) -> bool {
    !address.is_empty() && address.split(';').all(|part| part.starts_with("unix:"))
}
pub fn diagnostic(code: i32) -> &'static str {
    match code {
        2 => "Expected options followed by -- and exactly two file paths.",
        3 => "An input is missing, unreadable, or not a regular file.",
        4 => "Unsupported protocol option or version.",
        5 => "Fastra could not be started.",
        _ => "Fastra rejected the request or did not confirm it before the deadline.",
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub version: u32,
    pub id: String,
    pub deadline: f64,
    pub left_path: String,
    pub right_path: String,
    pub left_label: String,
    pub right_label: String,
    pub read_only: bool,
    pub focus_diff: bool,
}
impl Request {
    pub fn parse(args: &[String], directory: &Path) -> Result<Option<Self>, i32> {
        if args == ["--capabilities", "--json"] {
            return Ok(None);
        }
        if args.iter().map(String::len).sum::<usize>() > MAX_MESSAGE {
            return Err(2);
        }
        let (mut left_label, mut right_label) = (None, None);
        let (mut read_only, mut focus_diff) = (false, false);
        let mut i = 0;
        while i < args.len() && args[i] != "--" {
            match args[i].as_str() {
                "--left-label" | "--right-label" => {
                    let label = if args[i] == "--left-label" {
                        &mut left_label
                    } else {
                        &mut right_label
                    };
                    if label.is_some() || i + 1 == args.len() {
                        return Err(2);
                    }
                    *label = Some(args[i + 1].clone());
                    i += 2;
                }
                "--read-only" | "--focus-diff" => {
                    let flag = if args[i] == "--read-only" {
                        &mut read_only
                    } else {
                        &mut focus_diff
                    };
                    if *flag {
                        return Err(2);
                    }
                    *flag = true;
                    i += 1;
                }
                value => return Err(if value.starts_with("--") { 4 } else { 2 }),
            }
        }
        if i == args.len() || args.len() - i != 3 {
            return Err(2);
        }
        let path = |value: &str| -> Result<String, i32> {
            if value.is_empty() || value.contains('\0') {
                return Err(2);
            }
            let p = directory.join(value);
            if !p.is_absolute() {
                return Err(2);
            }
            p.to_str().map(str::to_owned).ok_or(2)
        };
        let left_path = path(&args[i + 1])?;
        let right_path = path(&args[i + 2])?;
        let label = |value: &str| {
            Path::new(value)
                .file_name()
                .and_then(|v| v.to_str())
                .unwrap_or(value)
                .to_owned()
        };
        let request = Self {
            version: 1,
            id: gio::glib::uuid_string_random().into(),
            deadline: now() + 10.,
            left_label: left_label.unwrap_or_else(|| label(&left_path)),
            right_label: right_label.unwrap_or_else(|| label(&right_path)),
            left_path,
            right_path,
            read_only,
            focus_diff,
        };
        request.validate(now())?;
        request.encode()?;
        Ok(Some(request))
    }
    pub fn encode(&self) -> Result<String, i32> {
        let bytes = serde_json::to_string(self).map_err(|_| 2)?;
        if bytes.len() > MAX_MESSAGE {
            Err(2)
        } else {
            Ok(bytes)
        }
    }
    pub fn decode(bytes: &str) -> Result<Self, i32> {
        if bytes.len() > MAX_MESSAGE {
            return Err(2);
        }
        let mut request: Self = serde_json::from_str(bytes).map_err(|_| 4)?;
        request.id.make_ascii_lowercase();
        Ok(request)
    }
    pub fn validate(&self, at: f64) -> Result<(), i32> {
        if self.version != 1 {
            return Err(4);
        }
        if !gio::glib::uuid_string_is_valid(&self.id) {
            return Err(2);
        }
        if !self.deadline.is_finite() || self.deadline <= at || self.deadline > at + 11. {
            return Err(6);
        }
        for value in [&self.left_path, &self.right_path] {
            if !value.starts_with('/') || value.contains('\0') {
                return Err(2);
            }
        }
        if self.left_label.contains('\0') || self.right_label.contains('\0') {
            return Err(2);
        }
        self.encode()?;
        Ok(())
    }
    pub fn validate_files(&self) -> Result<(), i32> {
        for path in [&self.left_path, &self.right_path] {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
                .open(path)
                .map_err(|_| 3)?;
            if !file.metadata().map_err(|_| 3)?.is_file() {
                return Err(3);
            }
        }
        Ok(())
    }
}
