use crate::router::Router;
use anyhow::Result;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Request, Response, StatusCode};
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use hyper_util::rt::TokioIo;
use http_body_util::BodyExt;
use http_body_util::Full;
use bytes::Bytes;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{watch, RwLock};

pub struct ProxyServer {
    bind_addr: SocketAddr,
    router: Arc<RwLock<Router>>,
}

impl ProxyServer {
    pub fn new(bind_addr: SocketAddr, router: Arc<RwLock<Router>>) -> Self {
        Self { bind_addr, router }
    }

    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) -> Result<()> {
        let listener = TcpListener::bind(self.bind_addr).await?;
        tracing::info!("proxy listening on {}", self.bind_addr);

        loop {
            tokio::select! {
                result = listener.accept() => {
                    let (stream, peer_addr) = result?;
                    let router = self.router.clone();
                    tokio::spawn(async move {
                        let io = TokioIo::new(stream);
                        let service = service_fn(move |req| {
                            let router = router.clone();
                            handle_request(req, router, peer_addr)
                        });
                        if let Err(e) = http1::Builder::new()
                            .preserve_header_case(true)
                            .serve_connection(io, service)
                            .with_upgrades()
                            .await
                        {
                            if !e.is_incomplete_message() {
                                tracing::debug!("connection error from {}: {}", peer_addr, e);
                            }
                        }
                    });
                }
                _ = shutdown.changed() => {
                    tracing::info!("proxy shutting down");
                    break;
                }
            }
        }

        Ok(())
    }
}

async fn handle_request(
    req: Request<Incoming>,
    router: Arc<RwLock<Router>>,
    _peer_addr: SocketAddr,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    // Extract host from request
    let host = req
        .headers()
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    // Look up upstream
    let upstream = {
        let r = router.read().await;
        r.resolve(host)
    };

    let upstream = match upstream {
        Some(addr) => addr,
        None => {
            return Ok(Response::builder()
                .status(StatusCode::BAD_GATEWAY)
                .body(Full::new(Bytes::from(format!(
                    "devspace: no route for host '{}'\n",
                    host
                ))))
                .unwrap());
        }
    };

    // Check for WebSocket upgrade
    let is_upgrade = req
        .headers()
        .get("upgrade")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.eq_ignore_ascii_case("websocket"));

    if is_upgrade {
        return handle_websocket_upgrade(req, upstream).await;
    }

    // Forward regular HTTP request
    forward_request(req, upstream).await
}

async fn forward_request(
    mut req: Request<Incoming>,
    upstream: SocketAddr,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    // Build the upstream URI
    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");

    let uri = format!("http://{}{}", upstream, path_and_query);

    // Add forwarding headers
    let host = req
        .headers()
        .get("host")
        .cloned();

    if let Some(host_val) = &host {
        req.headers_mut()
            .insert("x-forwarded-host", host_val.clone());
    }

    *req.uri_mut() = uri.parse().unwrap();

    // Create client and forward
    let client: Client<_, Incoming> =
        Client::builder(TokioExecutor::new()).build_http();

    match client.request(req).await {
        Ok(resp) => {
            let (parts, body) = resp.into_parts();
            let body_bytes = body
                .collect()
                .await
                .map(|c| c.to_bytes())
                .unwrap_or_default();
            Ok(Response::from_parts(parts, Full::new(body_bytes)))
        }
        Err(_e) => Ok(Response::builder()
            .status(StatusCode::BAD_GATEWAY)
            .body(Full::new(Bytes::from(
                "devspace: upstream connection failed\n",
            )))
            .unwrap()),
    }
}

async fn handle_websocket_upgrade(
    req: Request<Incoming>,
    upstream: SocketAddr,
) -> Result<Response<Full<Bytes>>, hyper::Error> {
    // For WebSocket upgrades, we need to:
    // 1. Send the upgrade request to upstream
    // 2. If upstream agrees, upgrade both connections
    // 3. Bridge the two TCP streams

    let path_and_query = req
        .uri()
        .path_and_query()
        .map(|pq| pq.as_str())
        .unwrap_or("/");

    let uri: hyper::Uri = format!("http://{}{}", upstream, path_and_query)
        .parse()
        .unwrap();

    // Connect to upstream
    let stream = match tokio::net::TcpStream::connect(upstream).await {
        Ok(s) => s,
        Err(_) => {
            return Ok(Response::builder()
                .status(StatusCode::BAD_GATEWAY)
                .body(Full::new(Bytes::from(
                    "devspace: upstream connection failed for websocket\n",
                )))
                .unwrap());
        }
    };

    let io = TokioIo::new(stream);

    let (mut sender, conn) = hyper::client::conn::http1::Builder::new()
        .preserve_header_case(true)
        .handshake(io)
        .await
        .unwrap();

    tokio::spawn(async move {
        if let Err(e) = conn.with_upgrades().await {
            tracing::debug!("upstream ws connection error: {}", e);
        }
    });

    // Forward the upgrade request
    let mut upstream_req = Request::builder()
        .method(req.method())
        .uri(uri);

    for (key, value) in req.headers() {
        upstream_req = upstream_req.header(key, value);
    }

    let upstream_req = upstream_req
        .body(Full::<Bytes>::new(Bytes::new()))
        .unwrap();

    let upstream_resp = match sender.send_request(upstream_req).await {
        Ok(resp) => resp,
        Err(_e) => {
            return Ok(Response::builder()
                .status(StatusCode::BAD_GATEWAY)
                .body(Full::new(Bytes::from(
                    "devspace: websocket upgrade failed\n",
                )))
                .unwrap());
        }
    };

    if upstream_resp.status() != StatusCode::SWITCHING_PROTOCOLS {
        let (parts, body) = upstream_resp.into_parts();
        let body_bytes = body
            .collect()
            .await
            .map(|c| c.to_bytes())
            .unwrap_or_default();
        return Ok(Response::from_parts(parts, Full::new(body_bytes)));
    }

    // Both sides agreed to upgrade. Bridge the two upgraded connections.
    // Spawn the bridge task — it takes ownership of both the client request
    // (to upgrade the client side) and the upstream response (to upgrade the upstream side).
    tokio::spawn(async move {
        let upgraded_client = match hyper::upgrade::on(req).await {
            Ok(u) => u,
            Err(e) => {
                tracing::debug!("client upgrade failed: {}", e);
                return;
            }
        };

        let upgraded_upstream = match hyper::upgrade::on(upstream_resp).await {
            Ok(u) => u,
            Err(e) => {
                tracing::debug!("upstream upgrade failed: {}", e);
                return;
            }
        };

        let mut client_io = TokioIo::new(upgraded_client);
        let mut upstream_io = TokioIo::new(upgraded_upstream);

        if let Err(e) =
            tokio::io::copy_bidirectional(&mut client_io, &mut upstream_io).await
        {
            tracing::debug!("websocket bridge ended: {}", e);
        }
    });

    // Build the 101 response to send back to the client.
    // hyper will handle the actual protocol switch after we return this.
    Ok(Response::builder()
        .status(StatusCode::SWITCHING_PROTOCOLS)
        .header("upgrade", "websocket")
        .header("connection", "Upgrade")
        .body(Full::new(Bytes::new()))
        .unwrap())
}
