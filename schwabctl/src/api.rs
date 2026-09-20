//! One authenticated client for every Schwab endpoint, and the error type
//! every command speaks.

use std::fmt;
use std::time::Duration;

use chrono::Utc;
use serde_json::{json, Value};

use crate::oauth::{self, TokenSet};
use crate::store::{Config, Keychain, APP_KEY, APP_SECRET, TOKENS};

pub const TRADER_BASE: &str = "https://api.schwabapi.com/trader/v1";
pub const MARKET_DATA_BASE: &str = "https://api.schwabapi.com/marketdata/v1";

/// Every way a command can fail. The `code` is the contract with the app:
/// `SchwabBridge` reads it off the JSON envelope and decides what a failure
/// means — a missing login, a refusal at the live gate, a rejection by the
/// broker, or a transport error that says nothing about the order.
#[derive(Debug)]
pub enum Error {
    Usage(String),
    NotConfigured(String),
    NotLoggedIn(String),
    /// The live gate, or a login that failed verification.
    Refused(String),
    /// Schwab saw the order and said no — final.
    Rejected(String),
    Http { status: u16, message: String, order: bool },
    RateLimited(String),
    Transport(String),
    Io(String),
}

impl Error {
    pub fn code(&self) -> &'static str {
        match self {
            Error::Usage(_) => "usage",
            Error::NotConfigured(_) => "not_configured",
            Error::NotLoggedIn(_) => "not_logged_in",
            Error::Refused(_) => "refused",
            Error::Rejected(_) => "rejected",
            Error::Http { .. } => "http",
            Error::RateLimited(_) => "rate_limited",
            Error::Transport(_) => "transport",
            Error::Io(_) => "io",
        }
    }

    pub fn exit_code(&self) -> i32 {
        match self {
            Error::Usage(_) => 1,
            Error::NotConfigured(_) | Error::NotLoggedIn(_) => 2,
            Error::Http { .. } | Error::RateLimited(_) => 3,
            Error::Refused(_) => 4,
            Error::Rejected(_) => 5,
            Error::Transport(_) | Error::Io(_) => 6,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Error::Usage(m)
            | Error::NotConfigured(m)
            | Error::NotLoggedIn(m)
            | Error::Refused(m)
            | Error::Rejected(m)
            | Error::RateLimited(m)
            | Error::Transport(m)
            | Error::Io(m) => m,
            Error::Http { message, .. } => message,
        }
    }

    pub fn envelope(&self) -> Value {
        let mut error = json!({ "code": self.code(), "message": self.message() });
        if let Error::Http { status, order, .. } = self {
            error["status"] = json!(status);
            if *order {
                error["order"] = json!(true);
            }
        }
        json!({ "error": error })
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code(), self.message())
    }
}

/// The `message` Schwab's error envelope carries, when it carries one.
pub fn message_in(body: &str) -> String {
    if let Ok(value) = serde_json::from_str::<Value>(body) {
        if let Some(message) = value.get("message").and_then(|v| v.as_str()) {
            return message.to_string();
        }
        if let Some(first) = value.get("errors").and_then(|v| v.as_array()).and_then(|a| a.first()) {
            let parts: Vec<&str> = ["title", "detail"]
                .iter()
                .filter_map(|k| first.get(*k).and_then(|v| v.as_str()))
                .collect();
            if !parts.is_empty() {
                return parts.join("：");
            }
        }
        if let Some(error) = value.get("error").and_then(|v| v.as_str()) {
            let detail = value.get("error_description").and_then(|v| v.as_str()).unwrap_or("");
            return format!("{error} {detail}").trim().to_string();
        }
    }
    let trimmed = body.trim();
    if trimmed.is_empty() {
        "无正文".to_string()
    } else {
        trimmed.chars().take(300).collect()
    }
}

pub fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(20))
        .user_agent(concat!("MayStock-schwabctl/", env!("CARGO_PKG_VERSION")))
        .build()
}

/// The keychain contents this process is allowed to hold in memory.
pub struct Credentials {
    pub app_key: String,
    pub app_secret: String,
    pub tokens: Option<TokenSet>,
}

impl Credentials {
    pub fn load() -> Result<Credentials, Error> {
        let app_key = Keychain::get(APP_KEY)?;
        let app_secret = Keychain::get(APP_SECRET)?;
        let (Some(app_key), Some(app_secret)) = (app_key, app_secret) else {
            return Err(Error::NotConfigured(
                "schwabctl 还没有 App Key/Secret，运行 schwabctl configure".into(),
            ));
        };
        let tokens = match Keychain::get(TOKENS)? {
            Some(text) => Some(
                serde_json::from_str(&text)
                    .map_err(|e| Error::Io(format!("钥匙串里的 token 无法解析：{e}")))?,
            ),
            None => None,
        };
        Ok(Credentials { app_key, app_secret, tokens })
    }

    pub fn save_tokens(&mut self, tokens: TokenSet) -> Result<(), Error> {
        let text = serde_json::to_string(&tokens).map_err(|e| Error::Io(e.to_string()))?;
        Keychain::set(TOKENS, &text)?;
        self.tokens = Some(tokens);
        Ok(())
    }
}

/// An authenticated session: refreshes the access token when it is about to
/// expire, retries a refused token once, and maps every status into `Error`.
pub struct Client {
    pub agent: ureq::Agent,
    pub credentials: Credentials,
    pub config: Config,
}

impl Client {
    pub fn load() -> Result<Client, Error> {
        Ok(Client { agent: agent(), credentials: Credentials::load()?, config: Config::load() })
    }

    /// A token good for at least two more minutes, refreshing if needed.
    pub fn access_token(&mut self) -> Result<String, Error> {
        let now = Utc::now();
        let Some(tokens) = self.credentials.tokens.clone() else {
            return Err(Error::NotLoggedIn("尚未登录嘉信，运行 schwabctl login".into()));
        };
        if tokens.access_valid(now, 120) {
            return Ok(tokens.access_token);
        }
        self.refresh(&tokens)
    }

    fn refresh(&mut self, previous: &TokenSet) -> Result<String, Error> {
        let now = Utc::now();
        if !previous.refresh_valid(now) {
            return Err(Error::NotLoggedIn(format!(
                "嘉信登录已于 {} 过期（refresh token 只有 7 天），运行 schwabctl login",
                previous.refresh_expires_at().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            )));
        }
        let fresh = oauth::refresh(
            &self.agent,
            &self.credentials.app_key,
            &self.credentials.app_secret,
            previous,
            now,
        )
        .map_err(|e| match e {
            // A refused refresh means the refresh token is dead early — the
            // login has to be redone, and the app should say so.
            Error::Refused(m) => Error::NotLoggedIn(format!("刷新 access token 被拒：{m}；运行 schwabctl login")),
            other => other,
        })?;
        let token = fresh.access_token.clone();
        self.credentials.save_tokens(fresh)?;
        Ok(token)
    }

    pub fn account_hash(&self) -> Result<String, Error> {
        self.config
            .account_hash
            .clone()
            .ok_or_else(|| Error::NotLoggedIn("没有选定账户：先 schwabctl login（或 schwabctl use --account）".into()))
    }

    pub fn get(&mut self, url: &str) -> Result<String, Error> {
        self.send("GET", url, None, false).map(|r| r.body)
    }

    /// Send with a bearer token; on a refused token, refresh once and retry.
    pub fn send(&mut self, method: &str, url: &str, body: Option<&str>, order: bool) -> Result<Reply, Error> {
        let token = self.access_token()?;
        match self.send_with(&token, method, url, body, order) {
            Err(Error::Http { status: 401, .. }) => {
                let tokens = self
                    .credentials
                    .tokens
                    .clone()
                    .ok_or_else(|| Error::NotLoggedIn("尚未登录嘉信".into()))?;
                let fresh = self.refresh(&tokens)?;
                self.send_with(&fresh, method, url, body, order)
            }
            other => other,
        }
    }

    fn send_with(&self, token: &str, method: &str, url: &str, body: Option<&str>, order: bool) -> Result<Reply, Error> {
        let request = self
            .agent
            .request(method, url)
            .set("Authorization", &format!("Bearer {token}"))
            .set("Accept", "application/json");
        let outcome = match body {
            Some(body) => request.set("Content-Type", "application/json").send_string(body),
            None => request.call(),
        };
        match outcome {
            Ok(response) => {
                let status = response.status();
                let location = response.header("Location").map(str::to_string);
                let body = response.into_string().map_err(|e| Error::Transport(e.to_string()))?;
                Ok(Reply { status, body, location })
            }
            Err(ureq::Error::Status(429, _)) => Err(Error::RateLimited("嘉信限频（429）：超过每分钟 120 次".into())),
            Err(ureq::Error::Status(status, response)) => {
                let body = response.into_string().unwrap_or_default();
                let message = message_in(&body);
                if order && (400..500).contains(&status) && status != 401 {
                    return Err(Error::Rejected(format!("HTTP {status}：{message}")));
                }
                Err(Error::Http { status, message, order })
            }
            Err(ureq::Error::Transport(transport)) => Err(Error::Transport(transport.to_string())),
        }
    }
}

pub struct Reply {
    pub status: u16,
    pub body: String,
    pub location: Option<String>,
}

pub fn parse_json(body: &str) -> Result<Value, Error> {
    if body.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(body).map_err(|e| Error::Transport(format!("嘉信返回无法解析：{e}")))
}

/// Percent-encode one query value.
pub fn query(pairs: &[(&str, &str)]) -> String {
    let mut out = url::form_urlencoded::Serializer::new(String::new());
    for (key, value) in pairs {
        out.append_pair(key, value);
    }
    out.finish()
}

/// `symbols=A,B` must keep its comma, which `form_urlencoded` would escape.
pub fn symbols_query(symbols: &[String]) -> String {
    symbols
        .iter()
        .map(|s| url::form_urlencoded::byte_serialize(s.trim().to_uppercase().as_bytes()).collect::<String>())
        .collect::<Vec<_>>()
        .join(",")
}
