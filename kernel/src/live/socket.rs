//! One reconnecting WebSocket loop, shared by every venue.
//!
//! Connecting, the opening exchange (a login, serial subscriptions), keeping
//! the connection alive, noticing a dead one and reconnecting with backoff are
//! written once here. What differs between venues — what to send, what counts
//! as an acknowledgement, which frames are protocol chatter — is a `Dialect`.

use std::future::Future;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use super::{net, now_ms, Feed, FeedState, Update};

/// One frame of the opening exchange.
pub struct Step {
    pub frame: String,
    /// Wait for the venue to acknowledge this frame before sending the next.
    pub await_ack: bool,
}

/// Where to connect and what to say, built fresh for every connection — a
/// login is signed with the clock at the moment it is sent, and a streamer
/// token expires.
pub struct Plan {
    pub url: String,
    pub steps: Vec<Step>,
}

/// How a venue keeps an idle connection open.
pub enum Keepalive {
    /// Send this text frame once the connection has been quiet this long.
    Text(&'static str, Duration),
    /// Send a WebSocket ping control frame on this interval.
    Ping(Duration),
    /// The server drives it (heartbeat requests, server pings).
    Server,
}

pub trait Dialect: Send + Sync + 'static {
    fn feed(&self) -> Feed;
    fn plan(&self) -> impl Future<Output = Result<Plan, String>> + Send;
    /// For a frame received while waiting on an acknowledgement: accepted,
    /// refused (with why), or not an acknowledgement at all.
    fn ack(&self, text: &str) -> Option<Result<(), String>>;
    /// A frame that must be answered at once (Deribit's heartbeat request).
    fn reply(&self, _text: &str) -> Option<String> {
        None
    }
    fn keepalive(&self) -> Keepalive;
    /// Reconnect after this long with no traffic at all.
    fn idle_timeout(&self) -> Duration;
    /// Protocol frames that carry no data (pongs, acknowledgements).
    fn is_chatter(&self, text: &str) -> bool;
}

enum SessionEnd {
    Closed(String),
    Refused(String),
}

/// How long a refused login waits before trying again. Retrying a rejected
/// key in a tight loop would only get the address rate-limited.
const REFUSAL_BACKOFF: Duration = Duration::from_secs(300);
const ACK_TIMEOUT: Duration = Duration::from_secs(15);

pub async fn run<D: Dialect>(dialect: D, updates: mpsc::Sender<Update>) {
    let feed = dialect.feed();
    let mut attempt: u32 = 0;
    loop {
        health(&updates, feed, FeedState::Connecting).await;
        let plan = match dialect.plan().await {
            Ok(plan) => plan,
            Err(reason) => {
                health(&updates, feed, FeedState::Degraded(reason)).await;
                tokio::time::sleep(backoff(attempt)).await;
                attempt = attempt.saturating_add(1);
                continue;
            }
        };
        let (ws, route) = match net::connect_ws(&plan.url).await {
            Ok(opened) => opened,
            Err(reason) => {
                health(&updates, feed, FeedState::Degraded(reason)).await;
                tokio::time::sleep(backoff(attempt)).await;
                attempt = attempt.saturating_add(1);
                continue;
            }
        };
        if route.fell_back_to_ipv6 {
            health(&updates, feed, FeedState::Degraded(format!("IPv4 全部连不上，改走 IPv6 {}", route.address))).await;
        }
        let opened = Instant::now();
        match session(&dialect, ws, plan.steps, &updates).await {
            SessionEnd::Refused(reason) => {
                health(&updates, feed, FeedState::Refused(reason)).await;
                tokio::time::sleep(REFUSAL_BACKOFF).await;
                attempt = 0;
            }
            SessionEnd::Closed(reason) => {
                health(&updates, feed, FeedState::Degraded(reason)).await;
                // A connection that stayed up a while starts the backoff over.
                if opened.elapsed() > Duration::from_secs(60) {
                    attempt = 0;
                }
                tokio::time::sleep(backoff(attempt)).await;
                attempt = attempt.saturating_add(1);
            }
        }
    }
}

async fn session<D: Dialect>(dialect: &D, ws: net::Ws, steps: Vec<Step>, updates: &mpsc::Sender<Update>) -> SessionEnd {
    let feed = dialect.feed();
    let (mut sink, mut stream) = ws.split();
    let mut last_traffic = Instant::now();
    let mut last_ping = Instant::now();

    for step in steps {
        if let Err(e) = sink.send(Message::Text(step.frame)).await {
            return SessionEnd::Closed(format!("发送失败：{e}"));
        }
        if !step.await_ack {
            continue;
        }
        let deadline = Instant::now() + ACK_TIMEOUT;
        loop {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return SessionEnd::Closed("等待交易所确认超时".into());
            };
            let message = match tokio::time::timeout(remaining, stream.next()).await {
                Err(_) => return SessionEnd::Closed("等待交易所确认超时".into()),
                Ok(None) => return SessionEnd::Closed("连接在确认前被关闭".into()),
                Ok(Some(Err(e))) => return SessionEnd::Closed(format!("{e}")),
                Ok(Some(Ok(message))) => message,
            };
            last_traffic = Instant::now();
            let Some(text) = text_of(&message) else {
                if let Message::Ping(payload) = message {
                    let _ = sink.send(Message::Pong(payload)).await;
                }
                continue;
            };
            if let Some(answer) = dialect.reply(&text) {
                let _ = sink.send(Message::Text(answer)).await;
            }
            match dialect.ack(&text) {
                Some(Ok(())) => break,
                Some(Err(reason)) => return SessionEnd::Refused(reason),
                None => {
                    if !dialect.is_chatter(&text) {
                        forward(updates, feed, text).await;
                    }
                }
            }
        }
    }
    health(updates, feed, FeedState::Live).await;

    let keepalive = dialect.keepalive();
    let poll = Duration::from_secs(2);
    loop {
        match tokio::time::timeout(poll, stream.next()).await {
            Err(_) => {}
            Ok(None) => return SessionEnd::Closed("对端关闭了连接".into()),
            Ok(Some(Err(e))) => return SessionEnd::Closed(format!("{e}")),
            Ok(Some(Ok(message))) => {
                last_traffic = Instant::now();
                match message {
                    Message::Ping(payload) => {
                        let _ = sink.send(Message::Pong(payload)).await;
                    }
                    Message::Close(frame) => {
                        let why = frame.map(|f| format!("{} {}", u16::from(f.code), f.reason)).unwrap_or_default();
                        return SessionEnd::Closed(format!("对端关闭：{why}"));
                    }
                    other => {
                        if let Some(text) = text_of(&other) {
                            if let Some(answer) = dialect.reply(&text) {
                                let _ = sink.send(Message::Text(answer)).await;
                            }
                            if !dialect.is_chatter(&text) {
                                forward(updates, feed, text).await;
                            }
                        }
                    }
                }
            }
        }
        let quiet = last_traffic.elapsed();
        if quiet > dialect.idle_timeout() {
            return SessionEnd::Closed(format!("{} 秒没有任何数据", quiet.as_secs()));
        }
        match &keepalive {
            Keepalive::Text(frame, after) if quiet >= *after && last_ping.elapsed() >= *after => {
                last_ping = Instant::now();
                if sink.send(Message::Text((*frame).to_string())).await.is_err() {
                    return SessionEnd::Closed("保活发送失败".into());
                }
            }
            Keepalive::Ping(every) if last_ping.elapsed() >= *every => {
                last_ping = Instant::now();
                if sink.send(Message::Ping(Vec::new())).await.is_err() {
                    return SessionEnd::Closed("保活发送失败".into());
                }
            }
            _ => {}
        }
    }
}

fn text_of(message: &Message) -> Option<String> {
    match message {
        Message::Text(text) => Some(text.clone()),
        Message::Binary(bytes) => String::from_utf8(bytes.clone()).ok(),
        _ => None,
    }
}

async fn forward(updates: &mpsc::Sender<Update>, feed: Feed, text: String) {
    let _ = updates.send(Update::Frame { feed, text, received_ms: now_ms() }).await;
}

pub(crate) async fn health(updates: &mpsc::Sender<Update>, feed: Feed, state: FeedState) {
    let _ = updates.send(Update::Health { feed, state }).await;
}

/// 0.5 s doubling to 30 s, with up to 30% jitter so a network blip does not
/// make every socket reconnect in the same instant.
fn backoff(attempt: u32) -> Duration {
    let base = (0.5 * 2f64.powi(attempt.min(8) as i32)).min(30.0);
    let jitter = (now_ms().rem_euclid(1000) as f64 / 1000.0) * base * 0.3;
    Duration::from_secs_f64(base + jitter)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_and_is_capped() {
        assert!(backoff(0) >= Duration::from_millis(500) && backoff(0) < Duration::from_millis(700));
        assert!(backoff(3) >= Duration::from_secs(4));
        assert!(backoff(20) <= Duration::from_secs(39));
    }
}
