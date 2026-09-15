//! One function per subcommand. Each returns the JSON it prints; the error
//! envelope and exit code are `main`'s.

use std::io::Read;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Value};

use crate::api::{self, Client, Credentials, Error, MARKET_DATA_BASE, TRADER_BASE};
use crate::oauth;
use crate::store::{Config, Keychain, APP_KEY, APP_SECRET, TOKENS};
use crate::{listener, Cli};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// ISO-8601 to the second, in UTC — the one shape the app's decoder reads.
fn stamp(date: DateTime<Utc>) -> String {
    date.to_rfc3339_opts(SecondsFormat::Secs, true)
}

pub fn version() -> Result<Value, Error> {
    Ok(json!({ "name": "schwabctl", "version": VERSION }))
}

/// Ask for the app key and secret without echo, and keep them in the
/// keychain. Never read from arguments: a secret on a command line is in
/// the shell history and the process list.
pub fn configure(callback: Option<String>) -> Result<Value, Error> {
    let mut config = Config::load();
    if let Some(callback) = callback {
        listener::port_of(&callback)?;
        config.callback = Some(callback);
    }
    eprintln!("从 developer.schwab.com → Dashboard → Apps → MayStock 复制 App Key 与 Secret；输入不会回显。");
    let key = rpassword::prompt_password("App Key: ").map_err(|e| Error::Io(format!("读取输入失败：{e}")))?;
    let key = key.trim().to_string();
    if key.is_empty() {
        return Err(Error::Usage("App Key 为空".into()));
    }
    let secret = rpassword::prompt_password("App Secret: ").map_err(|e| Error::Io(format!("读取输入失败：{e}")))?;
    let secret = secret.trim().to_string();
    if secret.is_empty() {
        return Err(Error::Usage("App Secret 为空".into()));
    }
    Keychain::set(APP_KEY, &key)?;
    Keychain::set(APP_SECRET, &secret)?;
    config.save()?;
    eprintln!("已存入钥匙串（服务 {}）。下一步：schwabctl login", crate::store::SERVICE);
    status()
}

/// The browser login. Listens on the callback's port, or takes the URL by
/// hand, then exchanges the code and remembers the account.
pub fn login(cli: &Cli, manual: bool, no_browser: bool, allow_missing_state: bool, timeout_secs: u64) -> Result<Value, Error> {
    let _ = cli;
    let mut credentials = Credentials::load()?;
    let mut config = Config::load();
    let callback = config.callback();
    let state = oauth::make_state();
    let url = oauth::authorize_url(&credentials.app_key, &callback, &state);

    eprintln!("授权地址：\n{url}\n");
    if !no_browser {
        let _ = std::process::Command::new("/usr/bin/open").arg(&url).status();
    }

    let received = if manual {
        prompt_url()?
    } else {
        let port = listener::port_of(&callback)?;
        eprintln!(
            "正在 127.0.0.1:{port} 上等待嘉信回调（最多 {timeout_secs} 秒）。\n\
             浏览器会提示证书不受信任——那是 schwabctl 自签的回环证书，点「高级 → 继续访问 127.0.0.1」即可。"
        );
        match listener::wait_for_callback(port, &Config::dir(), Duration::from_secs(timeout_secs)) {
            Ok(target) => target,
            Err(Error::Io(reason)) => {
                eprintln!("监听失败（{reason}），改为手工粘贴。");
                prompt_url()?
            }
            Err(other) => return Err(other),
        }
    };

    let parsed = oauth::parse_callback(&received)?;
    oauth::verify(&parsed, &state, allow_missing_state)?;
    let now = Utc::now();
    let tokens = oauth::exchange_code(
        &api::agent(),
        &credentials.app_key,
        &credentials.app_secret,
        &parsed.code,
        &callback,
        now,
    )?;
    credentials.save_tokens(tokens)?;
    eprintln!("已换取 token；refresh token 7 天后过期，届时再运行 schwabctl login。");

    // Remember which account orders go to: the one chosen earlier if it is
    // still there, else the first the login can see.
    let mut client = Client { agent: api::agent(), credentials, config: config.clone() };
    let accounts = client.get(&format!("{TRADER_BASE}/accounts/accountNumbers"))?;
    let refs = api::parse_json(&accounts)?;
    let list = refs.as_array().cloned().unwrap_or_default();
    let chosen = list
        .iter()
        .find(|r| r.get("hashValue").and_then(|v| v.as_str()) == config.account_hash.as_deref())
        .or_else(|| list.first())
        .cloned();
    config.account_count = Some(list.len());
    if let Some(account) = chosen {
        config.account_hash = account.get("hashValue").and_then(|v| v.as_str()).map(str::to_string);
        config.account_suffix = account
            .get("accountNumber")
            .and_then(|v| v.as_str())
            .map(|n| n.chars().rev().take(3).collect::<Vec<_>>().into_iter().rev().collect());
    }
    config.save()?;
    status()
}

fn prompt_url() -> Result<String, Error> {
    eprintln!("登录完成后浏览器会跳到 https://127.0.0.1:8182/?code=…（页面打不开也没关系）。把地址栏的整串 URL 粘到这里，回车：");
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| Error::Io(format!("读取输入失败：{e}")))?;
    Ok(line)
}

pub fn logout(all: bool) -> Result<Value, Error> {
    Keychain::delete(TOKENS)?;
    if all {
        Keychain::delete(APP_KEY)?;
        Keychain::delete(APP_SECRET)?;
    }
    let mut config = Config::load();
    config.account_hash = None;
    config.account_suffix = None;
    config.account_count = None;
    config.save()?;
    status()
}

/// No network, no secrets: what the account page shows.
pub fn status() -> Result<Value, Error> {
    let config = Config::load();
    let now = Utc::now();
    let credentials = match Credentials::load() {
        Ok(c) => Some(c),
        Err(Error::NotConfigured(_)) => None,
        Err(other) => return Err(other),
    };
    let tokens = credentials.as_ref().and_then(|c| c.tokens.clone());
    let logged_in = tokens.as_ref().map(|t| t.refresh_valid(now)).unwrap_or(false);
    Ok(json!({
        "configured": credentials.is_some(),
        "loggedIn": logged_in,
        "refreshIssuedAt": tokens.as_ref().map(|t| stamp(t.refresh_issued_at)),
        "refreshExpiresAt": tokens.as_ref().map(|t| stamp(t.refresh_expires_at())),
        "accessExpiresAt": tokens.as_ref().map(|t| stamp(t.access_expires_at)),
        "callback": config.callback(),
        "accountSuffix": config.account_suffix,
        "accountCount": config.account_count.unwrap_or(0),
        "version": VERSION,
    }))
}

/// A thirty-minute token for the app. The refresh token stays here.
pub fn token() -> Result<Value, Error> {
    let mut client = Client::load()?;
    let access = client.access_token()?;
    let expires = client
        .credentials
        .tokens
        .as_ref()
        .map(|t| t.access_expires_at)
        .unwrap_or(Utc::now());
    Ok(json!({ "accessToken": access, "expiresAt": stamp(expires) }))
}

pub fn accounts() -> Result<Value, Error> {
    let mut client = Client::load()?;
    api::parse_json(&client.get(&format!("{TRADER_BASE}/accounts/accountNumbers"))?)
}

/// Choose the account orders go to, by number or by hash.
pub fn use_account(account: &str) -> Result<Value, Error> {
    let mut client = Client::load()?;
    let refs = api::parse_json(&client.get(&format!("{TRADER_BASE}/accounts/accountNumbers"))?)?;
    let list = refs.as_array().cloned().unwrap_or_default();
    let found = list
        .iter()
        .find(|r| {
            r.get("hashValue").and_then(|v| v.as_str()) == Some(account)
                || r.get("accountNumber").and_then(|v| v.as_str()) == Some(account)
        })
        .ok_or_else(|| Error::Usage(format!("没有账户 {account}；schwabctl accounts 列出可用账户")))?;
    let mut config = client.config.clone();
    config.account_hash = found.get("hashValue").and_then(|v| v.as_str()).map(str::to_string);
    config.account_suffix = found
        .get("accountNumber")
        .and_then(|v| v.as_str())
        .map(|n| n.chars().rev().take(3).collect::<Vec<_>>().into_iter().rev().collect());
    config.account_count = Some(list.len());
    config.save()?;
    status()
}

pub fn account() -> Result<Value, Error> {
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    api::parse_json(&client.get(&format!("{TRADER_BASE}/accounts/{hash}?fields=positions"))?)
}

pub fn positions() -> Result<Value, Error> {
    let account = account()?;
    Ok(account
        .get("securitiesAccount")
        .and_then(|a| a.get("positions"))
        .cloned()
        .unwrap_or_else(|| json!([])))
}

pub fn orders(from: &str, to: &str, status: Option<&str>) -> Result<Value, Error> {
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    let mut pairs = vec![("fromEnteredTime", from), ("toEnteredTime", to), ("maxResults", "500")];
    if let Some(status) = status {
        pairs.push(("status", status));
    }
    api::parse_json(&client.get(&format!("{TRADER_BASE}/accounts/{hash}/orders?{}", api::query(&pairs)))?)
}

pub fn order(id: &str) -> Result<Value, Error> {
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    api::parse_json(&client.get(&format!("{TRADER_BASE}/accounts/{hash}/orders/{id}"))?)
}

/// The body: `-` for stdin, else a file path.
fn read_body(source: &str) -> Result<String, Error> {
    let mut text = String::new();
    if source == "-" {
        std::io::stdin()
            .read_to_string(&mut text)
            .map_err(|e| Error::Io(format!("读取 stdin 失败：{e}")))?;
    } else {
        text = std::fs::read_to_string(source).map_err(|e| Error::Io(format!("读取 {source} 失败：{e}")))?;
    }
    // Validate before sending: a malformed body is a usage error here, not a
    // 400 from Schwab that the app would have to interpret.
    let value: Value = serde_json::from_str(&text).map_err(|e| Error::Usage(format!("订单 JSON 无法解析：{e}")))?;
    if value.get("orderLegCollection").and_then(|v| v.as_array()).map(|a| a.is_empty()).unwrap_or(true) {
        return Err(Error::Usage("订单 JSON 没有 orderLegCollection".into()));
    }
    Ok(text)
}

/// The gate: nothing reaches Schwab's order endpoints without `--live`.
/// There is no demo account for a mistake to land in.
fn require_live(cli: &Cli) -> Result<(), Error> {
    if cli.live {
        Ok(())
    } else {
        Err(Error::Refused("schwabctl 只在 --live 下发送或撤销订单；嘉信没有模拟盘，模拟盘由 MayStock 本地撮合".into()))
    }
}

pub fn place(cli: &Cli, body: &str) -> Result<Value, Error> {
    require_live(cli)?;
    let text = read_body(body)?;
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    let reply = client.send("POST", &format!("{TRADER_BASE}/accounts/{hash}/orders"), Some(&text), true)?;
    let id = reply
        .location
        .as_deref()
        .and_then(|l| l.rsplit('/').next())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| Error::Transport(format!("下单响应（HTTP {}）没有 Location 头", reply.status)))?;
    eprintln!("schwabctl: 已发送订单 {id}");
    let mut out = json!({ "orderId": id });
    if let Ok(order) = client.get(&format!("{TRADER_BASE}/accounts/{hash}/orders/{id}")) {
        if let Ok(value) = api::parse_json(&order) {
            if let Some(status) = value.get("status") {
                out["status"] = status.clone();
            }
        }
    }
    Ok(out)
}

pub fn replace(cli: &Cli, id: &str, body: &str) -> Result<Value, Error> {
    require_live(cli)?;
    let text = read_body(body)?;
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    let reply = client.send("PUT", &format!("{TRADER_BASE}/accounts/{hash}/orders/{id}"), Some(&text), true)?;
    let new_id = reply
        .location
        .as_deref()
        .and_then(|l| l.rsplit('/').next())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| Error::Transport(format!("改单响应（HTTP {}）没有 Location 头", reply.status)))?;
    eprintln!("schwabctl: 已改单 {id} → {new_id}");
    Ok(json!({ "orderId": new_id, "replaced": id }))
}

pub fn cancel(cli: &Cli, id: &str) -> Result<Value, Error> {
    require_live(cli)?;
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    client.send("DELETE", &format!("{TRADER_BASE}/accounts/{hash}/orders/{id}"), None, true)?;
    eprintln!("schwabctl: 已撤单 {id}");
    Ok(json!({ "orderId": id, "canceled": true }))
}

pub fn fills(from: &str, to: &str, symbol: Option<&str>) -> Result<Value, Error> {
    let mut client = Client::load()?;
    let hash = client.account_hash()?;
    let mut pairs = vec![("startDate", from), ("endDate", to), ("types", "TRADE")];
    if let Some(symbol) = symbol {
        pairs.push(("symbol", symbol));
    }
    api::parse_json(&client.get(&format!("{TRADER_BASE}/accounts/{hash}/transactions?{}", api::query(&pairs)))?)
}

pub fn quotes(symbols: &[String]) -> Result<Value, Error> {
    if symbols.is_empty() {
        return Err(Error::Usage("至少给一个代码：schwabctl quotes TSLA QQQ".into()));
    }
    let mut client = Client::load()?;
    let url = format!(
        "{MARKET_DATA_BASE}/quotes?symbols={}&fields=quote,reference,regular,extended&indicative=false",
        api::symbols_query(symbols)
    );
    api::parse_json(&client.get(&url)?)
}

/// Schwab's frequency for a bar. There is no hourly frequency: the app
/// assembles hours from half-hours, so `1H` asks for thirty-minute bars.
fn frequency(bar: &str) -> Result<(&'static str, &'static str, &'static str), Error> {
    Ok(match bar {
        "1m" => ("day", "minute", "1"),
        "5m" => ("day", "minute", "5"),
        "15m" => ("day", "minute", "15"),
        "1H" | "1h" | "30m" => ("day", "minute", "30"),
        "1D" | "1d" => ("year", "daily", "1"),
        other => return Err(Error::Usage(format!("嘉信不提供 {other} K 线（可用 1m 5m 15m 1H 1D）"))),
    })
}

pub fn candles(symbol: &str, bar: &str, days: u32, extended: bool) -> Result<Value, Error> {
    let (period_type, frequency_type, freq) = frequency(bar)?;
    let mut client = Client::load()?;
    let end = Utc::now();
    let start = end - chrono::Duration::days(i64::from(days));
    let start_ms = start.timestamp_millis().to_string();
    let end_ms = end.timestamp_millis().to_string();
    let upper = symbol.trim().to_uppercase();
    let pairs = [
        ("symbol", upper.as_str()),
        ("periodType", period_type),
        ("frequencyType", frequency_type),
        ("frequency", freq),
        ("startDate", start_ms.as_str()),
        ("endDate", end_ms.as_str()),
        ("needExtendedHoursData", if extended { "true" } else { "false" }),
        ("needPreviousClose", "true"),
    ];
    api::parse_json(&client.get(&format!("{MARKET_DATA_BASE}/pricehistory?{}", api::query(&pairs)))?)
}

pub fn hours(date: Option<&str>) -> Result<Value, Error> {
    let mut client = Client::load()?;
    let mut pairs = vec![("markets", "equity")];
    if let Some(date) = date {
        pairs.push(("date", date));
    }
    api::parse_json(&client.get(&format!("{MARKET_DATA_BASE}/markets?{}", api::query(&pairs)))?)
}

/// Symbols starting with the query, then names containing it, as one
/// `instruments` list.
pub fn search(query: &str) -> Result<Value, Error> {
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Err(Error::Usage("给一个代码或名称：schwabctl search tesla".into()));
    }
    let mut client = Client::load()?;
    let mut instruments: Vec<Value> = Vec::new();
    let pattern = format!("{}.*", regex_escape(&trimmed.to_uppercase()));
    if let Ok(body) = client.get(&format!(
        "{MARKET_DATA_BASE}/instruments?{}",
        api::query(&[("symbol", pattern.as_str()), ("projection", "symbol-regex")])
    )) {
        if let Some(list) = api::parse_json(&body)?.get("instruments").and_then(|v| v.as_array()) {
            instruments.extend(list.iter().cloned());
        }
    }
    if trimmed.len() >= 2 {
        if let Ok(body) = client.get(&format!(
            "{MARKET_DATA_BASE}/instruments?{}",
            api::query(&[("symbol", trimmed), ("projection", "desc-search")])
        )) {
            if let Some(list) = api::parse_json(&body)?.get("instruments").and_then(|v| v.as_array()) {
                instruments.extend(list.iter().cloned());
            }
        }
    }
    let mut seen = std::collections::HashSet::new();
    instruments.retain(|i| {
        i.get("symbol")
            .and_then(|v| v.as_str())
            .map(|s| seen.insert(s.to_string()))
            .unwrap_or(false)
    });
    Ok(json!({ "instruments": instruments }))
}

fn regex_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if "\\.+*?()|[]{}^$".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}
