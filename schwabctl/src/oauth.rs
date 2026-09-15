//! The authorisation-code flow: URL, nonce, callback, token exchange.

use base64::Engine;
use chrono::{DateTime, Duration, Utc};
use ring::rand::SecureRandom;
use serde::{Deserialize, Serialize};

use crate::api::{self, Error};

pub const AUTHORIZE_URL: &str = "https://api.schwabapi.com/v1/oauth/authorize";
pub const TOKEN_URL: &str = "https://api.schwabapi.com/v1/oauth/token";
pub const DEFAULT_CALLBACK: &str = "https://127.0.0.1:8182";
/// Schwab expires a refresh token seven days after the login that minted
/// it, whether or not it is used.
pub const REFRESH_LIFETIME_SECS: i64 = 7 * 86_400;

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct TokenSet {
    pub access_token: String,
    pub access_expires_at: DateTime<Utc>,
    pub refresh_token: String,
    pub refresh_issued_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id_token: Option<String>,
}

impl TokenSet {
    pub fn refresh_expires_at(&self) -> DateTime<Utc> {
        self.refresh_issued_at + Duration::seconds(REFRESH_LIFETIME_SECS)
    }

    pub fn access_valid(&self, now: DateTime<Utc>, margin_secs: i64) -> bool {
        self.access_expires_at - now > Duration::seconds(margin_secs)
    }

    pub fn refresh_valid(&self, now: DateTime<Utc>) -> bool {
        now < self.refresh_expires_at()
    }
}

pub fn authorize_url(app_key: &str, callback: &str, state: &str) -> String {
    let mut url = url::Url::parse(AUTHORIZE_URL).expect("constant URL");
    url.query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", app_key)
        .append_pair("scope", "readonly")
        .append_pair("redirect_uri", callback)
        .append_pair("state", state);
    url.to_string()
}

/// 32 random bytes, URL-safe, no padding.
pub fn make_state() -> String {
    let mut bytes = [0u8; 32];
    ring::rand::SystemRandom::new().fill(&mut bytes).expect("system randomness");
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Callback {
    pub code: String,
    pub state: Option<String>,
}

/// Read the code out of whatever the browser handed back: the full URL from
/// the address bar, the request target the listener saw, or a bare query.
/// The URL parser percent-decodes, which is what turns the `%40` on the end
/// of every Schwab code back into the `@` the token endpoint expects.
pub fn parse_callback(text: &str) -> Result<Callback, Error> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err(Error::Usage("回调里没有 code 参数".into()));
    }
    let candidates = [
        trimmed.to_string(),
        format!("https://127.0.0.1/{trimmed}"),
        format!("https://127.0.0.1/?{trimmed}"),
    ];
    for candidate in candidates {
        let Ok(url) = url::Url::parse(&candidate) else { continue };
        let mut code = None;
        let mut state = None;
        for (key, value) in url.query_pairs() {
            match key.as_ref() {
                "code" if !value.is_empty() => code = Some(value.into_owned()),
                "state" if !value.is_empty() => state = Some(value.into_owned()),
                _ => {}
            }
        }
        if let Some(code) = code {
            return Ok(Callback { code, state });
        }
    }
    Err(Error::Usage("回调里没有 code 参数".into()))
}

/// Check the echoed nonce. Missing is refused unless explicitly accepted,
/// and accepting it is said out loud.
pub fn verify(callback: &Callback, expected: &str, allow_missing: bool) -> Result<(), Error> {
    match &callback.state {
        Some(state) if state == expected => Ok(()),
        Some(_) => Err(Error::Refused("回调的 state 与本次登录不符，已拒绝".into())),
        None if allow_missing => {
            eprintln!("schwabctl: 回调没有回传 state，按 --allow-missing-state 放行；本次只靠一次性 code 与本机监听保护");
            Ok(())
        }
        None => Err(Error::Refused(
            "回调没有回传 state，无法确认它来自本次登录（可用 --allow-missing-state 重试）".into(),
        )),
    }
}

fn basic(app_key: &str, app_secret: &str) -> String {
    format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("{app_key}:{app_secret}"))
    )
}

pub fn exchange_code(
    agent: &ureq::Agent,
    app_key: &str,
    app_secret: &str,
    code: &str,
    callback: &str,
    now: DateTime<Utc>,
) -> Result<TokenSet, Error> {
    let body = token_call(
        agent,
        app_key,
        app_secret,
        &[("grant_type", "authorization_code"), ("code", code), ("redirect_uri", callback)],
    )?;
    decode_token(&body, now, None)
}

pub fn refresh(
    agent: &ureq::Agent,
    app_key: &str,
    app_secret: &str,
    previous: &TokenSet,
    now: DateTime<Utc>,
) -> Result<TokenSet, Error> {
    let body = token_call(
        agent,
        app_key,
        app_secret,
        &[("grant_type", "refresh_token"), ("refresh_token", &previous.refresh_token)],
    )?;
    decode_token(&body, now, Some(previous))
}

fn token_call(agent: &ureq::Agent, app_key: &str, app_secret: &str, form: &[(&str, &str)]) -> Result<String, Error> {
    let response = agent
        .post(TOKEN_URL)
        .set("Authorization", &basic(app_key, app_secret))
        .set("Accept", "application/json")
        .send_form(form);
    match response {
        Ok(response) => response.into_string().map_err(|e| Error::Transport(e.to_string())),
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_string().unwrap_or_default();
            Err(Error::Refused(format!(
                "嘉信拒绝换取 token（HTTP {status}）：{}",
                api::message_in(&body)
            )))
        }
        Err(ureq::Error::Transport(transport)) => Err(Error::Transport(transport.to_string())),
    }
}

/// On a refresh the refresh token usually comes back unchanged and its
/// seven-day clock keeps running from the login; a code exchange starts it.
fn decode_token(body: &str, now: DateTime<Utc>, previous: Option<&TokenSet>) -> Result<TokenSet, Error> {
    let value: serde_json::Value =
        serde_json::from_str(body).map_err(|_| Error::Transport("token 响应不是 JSON".into()))?;
    if let Some(error) = value.get("error").and_then(|v| v.as_str()) {
        let detail = value.get("error_description").and_then(|v| v.as_str()).unwrap_or("");
        return Err(Error::Refused(format!("嘉信拒绝换取 token：{error} {detail}").trim().to_string()));
    }
    let access = value
        .get("access_token")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| Error::Transport("token 响应没有 access_token".into()))?;
    let expires_in = value.get("expires_in").and_then(|v| v.as_f64()).unwrap_or(1_800.0);
    let refresh = value
        .get("refresh_token")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| previous.map(|p| p.refresh_token.clone()))
        .ok_or_else(|| Error::Transport("token 响应没有 refresh_token".into()))?;
    let issued_at = match previous {
        Some(p) if p.refresh_token == refresh => p.refresh_issued_at,
        _ => now,
    };
    Ok(TokenSet {
        access_token: access.to_string(),
        access_expires_at: now + Duration::seconds(expires_in as i64),
        refresh_token: refresh,
        refresh_issued_at: issued_at,
        id_token: value.get("id_token").and_then(|v| v.as_str()).map(str::to_string),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn callback_decodes_the_code_and_state() {
        let parsed = parse_callback("https://127.0.0.1:8182/?code=C0.abc%40&state=xyz&session=1").unwrap();
        assert_eq!(parsed.code, "C0.abc@");
        assert_eq!(parsed.state.as_deref(), Some("xyz"));
        let bare = parse_callback("code=C0.abc%40").unwrap();
        assert_eq!(bare.code, "C0.abc@");
        assert!(bare.state.is_none());
        let target = parse_callback("/?code=C0.abc%40&state=s").unwrap();
        assert_eq!(target.code, "C0.abc@");
        assert!(parse_callback("https://127.0.0.1:8182/?session=1").is_err());
    }

    #[test]
    fn state_is_required_unless_waived() {
        let with = Callback { code: "c".into(), state: Some("s".into()) };
        assert!(verify(&with, "s", false).is_ok());
        assert!(verify(&with, "other", true).is_err());
        let without = Callback { code: "c".into(), state: None };
        assert!(verify(&without, "s", false).is_err());
        assert!(verify(&without, "s", true).is_ok());
    }

    #[test]
    fn refresh_keeps_the_login_clock() {
        let now = Utc::now();
        let first = decode_token(
            r#"{"access_token":"a","refresh_token":"r","expires_in":1800}"#,
            now,
            None,
        )
        .unwrap();
        assert_eq!(first.refresh_issued_at, now);
        let later = now + Duration::hours(5);
        let refreshed = decode_token(r#"{"access_token":"b","expires_in":1800}"#, later, Some(&first)).unwrap();
        assert_eq!(refreshed.refresh_token, "r");
        assert_eq!(refreshed.refresh_issued_at, now);
        assert!(refreshed.access_valid(later, 120));
        assert!(refreshed.refresh_valid(now + Duration::days(6)));
        assert!(!refreshed.refresh_valid(now + Duration::days(8)));
        let rotated = decode_token(r#"{"access_token":"c","refresh_token":"r2"}"#, later, Some(&first)).unwrap();
        assert_eq!(rotated.refresh_issued_at, later);
    }

    #[test]
    fn authorize_url_carries_the_nonce() {
        let url = authorize_url("KEY", "https://127.0.0.1:8182", "nonce");
        assert!(url.starts_with(AUTHORIZE_URL));
        assert!(url.contains("client_id=KEY"));
        assert!(url.contains("redirect_uri=https%3A%2F%2F127.0.0.1%3A8182"));
        assert!(url.contains("state=nonce"));
    }
}
