//! Getting a connection open quickly on this machine's network.
//!
//! Measured on 2026-09-23 behind the corporate VPN: every exchange host
//! advertises IPv6 addresses that are black-holed here, and the system
//! resolver tries them first. A connection then sits in a ten-second timeout
//! before falling back to IPv4 — which is where `okx` CLI calls dying at 15
//! seconds, and a 10.6 s TCP connect to www.okx.com, came from. OKX's two IPv4
//! edges also differed by an order of magnitude (0.2 s against 3 s).
//!
//! So sockets are opened by racing every IPv4 address at once and keeping the
//! first to answer; IPv6 is tried only when no IPv4 address connects, and that
//! fallback is reported, not taken silently.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::net::TcpStream;
use tokio::task::JoinSet;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

pub type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// How the connection was made, for the feed's health line.
#[derive(Debug, Clone)]
pub struct Route {
    pub address: SocketAddr,
    /// True when no IPv4 address answered and IPv6 was used instead.
    pub fell_back_to_ipv6: bool,
}

const PER_ADDRESS_TIMEOUT: Duration = Duration::from_secs(4);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

/// Open a TCP connection to the fastest reachable address of `host`.
pub async fn connect_fastest(host: &str, port: u16) -> Result<(TcpStream, Route), String> {
    let addresses: Vec<SocketAddr> = tokio::net::lookup_host((host, port))
        .await
        .map_err(|e| format!("解析 {host} 失败：{e}"))?
        .collect();
    let (v4, v6): (Vec<SocketAddr>, Vec<SocketAddr>) = addresses.into_iter().partition(SocketAddr::is_ipv4);
    if let Some(stream) = race(&v4).await {
        return Ok((stream.0, Route { address: stream.1, fell_back_to_ipv6: false }));
    }
    if let Some(stream) = race(&v6).await {
        return Ok((stream.0, Route { address: stream.1, fell_back_to_ipv6: true }));
    }
    Err(format!("{host}:{port} 的 {} 个 IPv4 与 {} 个 IPv6 地址都连不上", v4.len(), v6.len()))
}

async fn race(addresses: &[SocketAddr]) -> Option<(TcpStream, SocketAddr)> {
    let mut attempts = JoinSet::new();
    for address in addresses.iter().copied() {
        attempts.spawn(async move {
            match tokio::time::timeout(PER_ADDRESS_TIMEOUT, TcpStream::connect(address)).await {
                Ok(Ok(stream)) => Some((stream, address)),
                _ => None,
            }
        });
    }
    while let Some(result) = attempts.join_next().await {
        if let Ok(Some((stream, address))) = result {
            let _ = stream.set_nodelay(true);
            attempts.abort_all();
            return Some((stream, address));
        }
    }
    None
}

/// Open a WebSocket (TLS for `wss://`) over the fastest address.
pub async fn connect_ws(url: &str) -> Result<(Ws, Route), String> {
    let (host, port) = host_and_port(url)?;
    let (tcp, route) = connect_fastest(&host, port).await?;
    let handshake = tokio_tungstenite::client_async_tls(url, tcp);
    match tokio::time::timeout(HANDSHAKE_TIMEOUT, handshake).await {
        Ok(Ok((ws, _response))) => Ok((ws, route)),
        Ok(Err(e)) => Err(format!("WebSocket 握手失败：{e}")),
        Err(_) => Err(format!("WebSocket 握手超过 {} 秒", HANDSHAKE_TIMEOUT.as_secs())),
    }
}

fn host_and_port(url: &str) -> Result<(String, u16), String> {
    let (scheme, rest) = url.split_once("://").ok_or_else(|| format!("不是 URL：{url}"))?;
    let authority = rest.split(['/', '?']).next().unwrap_or("");
    let default_port = if scheme == "wss" || scheme == "https" { 443 } else { 80 };
    match authority.rsplit_once(':') {
        Some((host, port)) => {
            let port = port.parse::<u16>().map_err(|_| format!("端口不对：{url}"))?;
            Ok((host.to_string(), port))
        }
        None => Ok((authority.to_string(), default_port)),
    }
}

/// DNS for the REST clients, applying `connect_fastest`'s rule to requests:
/// every IPv4 address of the host is raced, and the one that answers first
/// is handed to the connector first. Without it the connector tries the
/// addresses in the resolver's order, and when that order starts with a
/// slow or dead edge a whole burst of connections times out together —
/// measured 2026-09-25: fifteen concurrent first connections to www.okx.com
/// all ended "client error (Connect): operation timed out", one run in about
/// twelve. The order is remembered for a minute, and one race runs at a time,
/// so a burst pays for a single race.
pub struct FastestFirst {
    port: u16,
    remembered: Arc<tokio::sync::Mutex<Remembered>>,
}

/// Each host's addresses, winner first, and when that race was run.
type Remembered = HashMap<String, (Instant, Vec<SocketAddr>)>;

/// How long a race's winner is trusted.
const REMEMBER: Duration = Duration::from_secs(60);

impl FastestFirst {
    /// For hosts reached on `port` — 443 for every https endpoint here.
    pub fn new(port: u16) -> Arc<FastestFirst> {
        Arc::new(FastestFirst { port, remembered: Arc::new(tokio::sync::Mutex::new(HashMap::new())) })
    }
}

impl reqwest::dns::Resolve for FastestFirst {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let host = name.as_str().to_string();
        let port = self.port;
        let remembered = Arc::clone(&self.remembered);
        Box::pin(async move {
            let mut cache = remembered.lock().await;
            if let Some((at, addresses)) = cache.get(&host) {
                if at.elapsed() < REMEMBER {
                    return Ok(Box::new(addresses.clone().into_iter()) as reqwest::dns::Addrs);
                }
            }
            let addresses: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), port)).await?.collect();
            let (v4, v6): (Vec<SocketAddr>, Vec<SocketAddr>) = addresses.into_iter().partition(SocketAddr::is_ipv4);
            let ordered = match race(&v4).await {
                Some((_, winner)) => {
                    let mut ordered = vec![winner];
                    ordered.extend(v4.iter().copied().filter(|a| *a != winner));
                    ordered.extend(v6);
                    cache.insert(host, (Instant::now(), ordered.clone()));
                    ordered
                }
                // Nothing answered: hand back everything, IPv4 first, and
                // remember nothing — the connector's own failure is reported.
                None => v4.into_iter().chain(v6).collect(),
            };
            Ok(Box::new(ordered.into_iter()) as reqwest::dns::Addrs)
        })
    }
}

/// The HTTP client every REST poll shares.
///
/// Bound to the IPv4 wildcard address, which makes the connector attempt only
/// IPv4 destinations, and resolved through `FastestFirst` — the same reasons
/// as `connect_fastest`, for requests.
pub fn http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .dns_resolver(FastestFirst::new(443))
        .local_address(IpAddr::V4(Ipv4Addr::UNSPECIFIED))
        .connect_timeout(Duration::from_secs(6))
        .timeout(Duration::from_secs(25))
        .pool_idle_timeout(Duration::from_secs(90))
        .user_agent("Mozilla/5.0 MayStock")
        .gzip(true)
        .build()
        .map_err(|e| format!("HTTP 客户端创建失败：{e}"))
}

/// GET a URL and return the body as text, with the status checked.
pub async fn get_text(client: &reqwest::Client, url: &str, bearer: Option<&str>) -> Result<String, String> {
    let mut request = client.get(url);
    if let Some(token) = bearer {
        request = request.bearer_auth(token);
    }
    let response = request.send().await.map_err(|e| describe(url, &e))?;
    let status = response.status();
    let body = response.text().await.map_err(|e| describe(url, &e))?;
    if !status.is_success() {
        let head: String = body.chars().take(160).collect();
        return Err(format!("HTTP {} {}：{head}", status.as_u16(), short(url)));
    }
    Ok(body)
}

fn describe(url: &str, error: &reqwest::Error) -> String {
    if error.is_timeout() {
        format!("{} 超时", short(url))
    } else if error.is_connect() {
        format!("{} 连不上", short(url))
    } else {
        format!("{}：{error}", short(url))
    }
}

/// Host and path without the query, for error lines.
fn short(url: &str) -> String {
    let without_scheme = url.split_once("://").map(|(_, rest)| rest).unwrap_or(url);
    without_scheme.split('?').next().unwrap_or(without_scheme).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_hosts_and_ports_from_urls() {
        assert_eq!(host_and_port("wss://ws.okx.com:8443/ws/v5/public").unwrap(), ("ws.okx.com".into(), 8443));
        assert_eq!(host_and_port("wss://www.deribit.com/ws/api/v2").unwrap(), ("www.deribit.com".into(), 443));
        assert_eq!(host_and_port("https://api.bybit.com/v5?x=1").unwrap(), ("api.bybit.com".into(), 443));
        assert!(host_and_port("not a url").is_err());
    }

    #[test]
    fn the_fastest_address_is_handed_back_first_and_remembered() {
        use reqwest::dns::Resolve;
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            // Only IPv4 localhost listens, so it must win the race.
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            tokio::spawn(async move { loop { let _ = listener.accept().await; } });
            let resolver = FastestFirst::new(port);
            let first: Vec<SocketAddr> = resolver.resolve("localhost".parse().unwrap()).await.unwrap().collect();
            assert_eq!(first.first().map(|a| a.ip()), Some(IpAddr::V4(Ipv4Addr::LOCALHOST)), "{first:?}");
            assert_eq!(resolver.remembered.lock().await.len(), 1, "the winner is remembered");
            let again: Vec<SocketAddr> = resolver.resolve("localhost".parse().unwrap()).await.unwrap().collect();
            assert_eq!(again, first);
        });
    }

    #[test]
    fn error_lines_drop_the_query() {
        assert_eq!(short("https://eapi.binance.com/eapi/v1/openInterest?underlyingAsset=ETH"), "eapi.binance.com/eapi/v1/openInterest");
    }
}
