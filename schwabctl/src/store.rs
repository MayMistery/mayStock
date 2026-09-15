//! Where the secrets live, and where the settings that are not secrets live.
//!
//! Secrets — the app key, the app secret, both OAuth tokens — go into the login
//! keychain through `/usr/bin/security`, the same way `gh` and every other
//! CLI on this machine stores a credential. Going through the system tool
//! rather than the Security framework means the keychain ACL trusts the tool,
//! not this binary, so a rebuilt `schwabctl` reads what the previous build
//! wrote without a dialog. The cost is that any process running as the user
//! can ask the same tool — the same bar a mode-0600 file sets, which is what
//! every alternative store here would have been.
//!
//! Everything else — the callback, the chosen account — is a JSON file next
//! to the loopback certificate, readable so a human can check it.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::Error;

pub const SERVICE: &str = "com.maystock.schwabctl";
pub const APP_KEY: &str = "app-key";
pub const APP_SECRET: &str = "app-secret";
pub const TOKENS: &str = "tokens";

pub struct Keychain;

impl Keychain {
    /// The secret under `account`, or `None` when the keychain has none.
    pub fn get(account: &str) -> Result<Option<String>, Error> {
        let output = Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", SERVICE, "-a", account, "-w"])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| Error::Io(format!("无法运行 security：{e}")))?;
        // 44 is errSecItemNotFound: nothing stored, which is an answer.
        if output.status.code() == Some(44) {
            return Ok(None);
        }
        if !output.status.success() {
            return Err(Error::Io(format!(
                "security find-generic-password 失败：{}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        let text = String::from_utf8_lossy(&output.stdout).trim_end_matches(['\r', '\n']).to_string();
        Ok(if text.is_empty() { None } else { Some(text) })
    }

    /// Store, replacing what is there. The secret goes over stdin to the
    /// tool's interactive mode so it never appears in a process listing.
    pub fn set(account: &str, secret: &str) -> Result<(), Error> {
        let escaped = secret.replace('\\', "\\\\").replace('"', "\\\"");
        let line = format!(
            "add-generic-password -U -s \"{SERVICE}\" -a \"{account}\" -l \"MayStock schwabctl ({account})\" -w \"{escaped}\"\n"
        );
        let mut child = Command::new("/usr/bin/security")
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| Error::Io(format!("无法运行 security：{e}")))?;
        child
            .stdin
            .take()
            .ok_or_else(|| Error::Io("security 没有 stdin".into()))?
            .write_all(line.as_bytes())
            .map_err(|e| Error::Io(format!("写入 security 失败：{e}")))?;
        let output = child.wait_with_output().map_err(|e| Error::Io(format!("等待 security 失败：{e}")))?;
        let stderr = String::from_utf8_lossy(&output.stderr);
        if !output.status.success() || stderr.contains("Error") || stderr.contains("error") {
            return Err(Error::Io(format!("写入钥匙串失败：{}", stderr.trim())));
        }
        // Read back: the interactive mode reports some failures with exit 0.
        match Self::get(account)? {
            Some(stored) if stored == secret => Ok(()),
            _ => Err(Error::Io(format!("钥匙串回读 {account} 与写入不一致"))),
        }
    }

    pub fn delete(account: &str) -> Result<(), Error> {
        let output = Command::new("/usr/bin/security")
            .args(["delete-generic-password", "-s", SERVICE, "-a", account])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| Error::Io(format!("无法运行 security：{e}")))?;
        if output.status.success() || output.status.code() == Some(44) {
            Ok(())
        } else {
            Err(Error::Io(format!(
                "security delete-generic-password 失败：{}",
                String::from_utf8_lossy(&output.stderr).trim()
            )))
        }
    }
}

/// Non-secret settings.
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    /// The callback registered on the app; the login listens on its port.
    pub callback: Option<String>,
    /// The account orders go to, as Schwab's opaque hash.
    pub account_hash: Option<String>,
    /// Its last three digits, for display.
    pub account_suffix: Option<String>,
    pub account_count: Option<usize>,
}

impl Config {
    pub fn dir() -> PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        PathBuf::from(home).join("Library/Application Support/MayStock/schwab")
    }

    fn path() -> PathBuf {
        Self::dir().join("schwabctl.json")
    }

    pub fn load() -> Config {
        fs::read(Self::path())
            .ok()
            .and_then(|data| serde_json::from_slice(&data).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> Result<(), Error> {
        let dir = Self::dir();
        fs::create_dir_all(&dir).map_err(|e| Error::Io(format!("创建 {} 失败：{e}", dir.display())))?;
        let data = serde_json::to_vec_pretty(self).map_err(|e| Error::Io(e.to_string()))?;
        fs::write(Self::path(), data).map_err(|e| Error::Io(format!("写入配置失败：{e}")))
    }

    pub fn callback(&self) -> String {
        self.callback.clone().unwrap_or_else(|| crate::oauth::DEFAULT_CALLBACK.to_string())
    }
}
