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

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::time::Duration;

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

/// The HTTP client every REST poll shares.
///
/// Bound to the IPv4 wildcard address, which makes the connector attempt only
/// IPv4 destinations — the same reason as `connect_fastest`, for requests.
pub fn http_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
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
    fn error_lines_drop_the_query() {
        assert_eq!(short("https://eapi.binance.com/eapi/v1/openInterest?underlyingAsset=ETH"), "eapi.binance.com/eapi/v1/openInterest");
    }
}
