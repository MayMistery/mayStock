//! The loopback HTTPS listener the browser is redirected to after login.
//!
//! Bound to 127.0.0.1 only — never 0.0.0.0 — for the port the registered
//! callback names, alive only while a login is in progress, and closed the
//! moment one request carrying a `code` has been answered. The certificate
//! is self-signed for the loopback address and kept on disk so the browser
//! sees the same one every week; the warning it shows the first time is
//! expected, and the page it lands on says so.

use std::fs;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, TcpStream};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

use crate::api::Error;

const CERT_FILE: &str = "loopback-cert.pem";
const KEY_FILE: &str = "loopback-key.pem";

/// The certificate and key for 127.0.0.1, minted on first use.
fn identity(dir: &Path) -> Result<(CertificateDer<'static>, PrivateKeyDer<'static>), Error> {
    let cert_path = dir.join(CERT_FILE);
    let key_path = dir.join(KEY_FILE);
    if let (Ok(cert_pem), Ok(key_pem)) = (fs::read_to_string(&cert_path), fs::read_to_string(&key_path)) {
        if let (Some(cert), Ok(key)) = (pem_body(&cert_pem), rcgen::KeyPair::from_pem(&key_pem)) {
            let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der()));
            return Ok((CertificateDer::from(cert), key_der));
        }
        eprintln!("schwabctl: 已有的回环证书读不出来，重新生成");
    }
    let generated = rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_string()])
        .map_err(|e| Error::Io(format!("生成回环证书失败：{e}")))?;
    fs::create_dir_all(dir).map_err(|e| Error::Io(format!("创建 {} 失败：{e}", dir.display())))?;
    fs::write(&cert_path, generated.cert.pem()).map_err(|e| Error::Io(format!("写证书失败：{e}")))?;
    fs::write(&key_path, generated.key_pair.serialize_pem()).map_err(|e| Error::Io(format!("写私钥失败：{e}")))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600));
    }
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(generated.key_pair.serialize_der()));
    Ok((generated.cert.der().clone(), key_der))
}

/// The DER between the first BEGIN/END pair of a PEM file.
fn pem_body(pem: &str) -> Option<Vec<u8>> {
    let mut inside = false;
    let mut body = String::new();
    for line in pem.lines() {
        if line.starts_with("-----BEGIN") {
            inside = true;
            continue;
        }
        if line.starts_with("-----END") {
            break;
        }
        if inside {
            body.push_str(line.trim());
        }
    }
    base64::engine::general_purpose::STANDARD.decode(body).ok()
}

/// Wait for the browser to arrive with a code. Returns the request target
/// (`/?code=…&state=…`), which `oauth::parse_callback` reads.
pub fn wait_for_callback(port: u16, dir: &Path, timeout: Duration) -> Result<String, Error> {
    let (cert, key) = identity(dir)?;
    let config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| Error::Io(format!("TLS 配置失败：{e}")))?;
    let config = Arc::new(config);

    let address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let listener = TcpListener::bind(address).map_err(|e| Error::Io(format!("无法监听 {address}：{e}")))?;
    listener
        .set_nonblocking(true)
        .map_err(|e| Error::Io(format!("监听设置失败：{e}")))?;
    let deadline = Instant::now() + timeout;

    loop {
        if Instant::now() >= deadline {
            return Err(Error::Refused(format!("等待浏览器回调超过 {} 秒，登录已放弃", timeout.as_secs())));
        }
        match listener.accept() {
            Ok((stream, _)) => {
                if let Some(target) = serve(stream, config.clone()) {
                    return Ok(target);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(150));
            }
            Err(e) => return Err(Error::Io(format!("接受连接失败：{e}"))),
        }
    }
}

/// Handle one connection. Returns the target when it carried a code; a
/// probe, a favicon request or a failed handshake returns nothing and the
/// loop keeps listening.
fn serve(mut tcp: TcpStream, config: Arc<rustls::ServerConfig>) -> Option<String> {
    let _ = tcp.set_nonblocking(false);
    let _ = tcp.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = tcp.set_write_timeout(Some(Duration::from_secs(5)));
    let mut connection = rustls::ServerConnection::new(config).ok()?;
    let mut tls = rustls::Stream::new(&mut connection, &mut tcp);

    let mut request = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        match tls.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                request.extend_from_slice(&chunk[..n]);
                if request.windows(4).any(|w| w == b"\r\n\r\n") || request.len() > 16 * 1024 {
                    break;
                }
            }
            Err(_) => return None,
        }
    }
    let text = String::from_utf8_lossy(&request);
    let target = text.lines().next().and_then(|line| line.split_whitespace().nth(1)).map(str::to_string);
    let Some(target) = target else {
        let _ = respond(&mut tls, 400, "Bad request");
        return None;
    };
    if target.contains("code=") {
        let _ = respond(
            &mut tls,
            200,
            "<!doctype html><meta charset=utf-8><title>MayStock</title>\
             <body style=\"font-family:-apple-system,sans-serif;padding:40px\">\
             <h2>嘉信登录完成</h2><p>schwabctl 已收到授权码，正在换取 token。可以关闭这个页面回到终端。</p></body>",
        );
        let _ = tls.conn.send_close_notify();
        let _ = tls.flush();
        Some(target)
    } else {
        let _ = respond(&mut tls, 404, "MayStock schwabctl: waiting for the Schwab callback");
        None
    }
}

fn respond(tls: &mut rustls::Stream<'_, rustls::ServerConnection, TcpStream>, status: u16, body: &str) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        _ => "Not Found",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    tls.write_all(response.as_bytes())?;
    tls.flush()
}

/// The port a callback URL names; 443 when it names none.
pub fn port_of(callback: &str) -> Result<u16, Error> {
    let url = url::Url::parse(callback).map_err(|e| Error::Usage(format!("回调地址无法解析：{e}")))?;
    if url.scheme() != "https" {
        return Err(Error::Usage("嘉信只接受 https 回调".into()));
    }
    match url.host_str() {
        Some("127.0.0.1") => {}
        Some(other) => {
            return Err(Error::Usage(format!(
                "回调主机是 {other}，schwabctl 只在 127.0.0.1 上监听；用 --manual 手工粘贴"
            )))
        }
        None => return Err(Error::Usage("回调地址没有主机".into())),
    }
    Ok(url.port().unwrap_or(443))
}
