use crate::port_watcher::ProjectRegistry;
use crate::router::Router;
use localport_core::validation;
use localport_proto::messages::{self, Response};
use localport_proto::methods;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{watch, RwLock};

pub struct IpcServer {
    socket_path: PathBuf,
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    tld: String,
    shutdown_tx: watch::Sender<bool>,
}

impl IpcServer {
    pub fn new(
        socket_path: PathBuf,
        router: Arc<RwLock<Router>>,
        projects: Arc<RwLock<ProjectRegistry>>,
        tld: String,
        shutdown_tx: watch::Sender<bool>,
    ) -> Self {
        Self {
            socket_path,
            router,
            projects,
            tld,
            shutdown_tx,
        }
    }

    pub async fn run(&self, mut shutdown: watch::Receiver<bool>) -> anyhow::Result<()> {
        // Remove stale socket file
        let _ = std::fs::remove_file(&self.socket_path);

        let listener = UnixListener::bind(&self.socket_path)?;
        tracing::info!("IPC listening on {}", self.socket_path.display());

        loop {
            tokio::select! {
                result = listener.accept() => {
                    let (stream, _) = result?;
                    let handler = ConnectionHandler {
                        router: self.router.clone(),
                        projects: self.projects.clone(),
                        tld: self.tld.clone(),
                        shutdown_tx: self.shutdown_tx.clone(),
                    };
                    tokio::spawn(async move {
                        if let Err(e) = handler.handle(stream).await {
                            tracing::debug!("IPC connection error: {}", e);
                        }
                    });
                }
                _ = shutdown.changed() => {
                    tracing::info!("IPC server shutting down");
                    let _ = std::fs::remove_file(&self.socket_path);
                    break;
                }
            }
        }

        Ok(())
    }
}

struct ConnectionHandler {
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    tld: String,
    shutdown_tx: watch::Sender<bool>,
}

impl ConnectionHandler {
    async fn handle(&self, stream: tokio::net::UnixStream) -> anyhow::Result<()> {
        let (reader, mut writer) = stream.into_split();
        let mut lines = BufReader::new(reader).lines();

        while let Some(line) = lines.next_line().await? {
            let request: messages::Request = match serde_json::from_str(&line) {
                Ok(r) => r,
                Err(e) => {
                    let resp = Response::error(0, messages::PARSE_ERROR, e.to_string());
                    let mut json = serde_json::to_string(&resp)?;
                    json.push('\n');
                    writer.write_all(json.as_bytes()).await?;
                    continue;
                }
            };

            let response = self.dispatch(&request).await;
            let mut json = serde_json::to_string(&response)?;
            json.push('\n');
            writer.write_all(json.as_bytes()).await?;
        }

        Ok(())
    }

    async fn dispatch(&self, req: &messages::Request) -> Response {
        match req.method.as_str() {
            methods::DAEMON_STATUS => self.handle_daemon_status(req.id).await,
            methods::PROJECT_STATUS => self.handle_project_status(req.id).await,
            methods::PROJECT_INIT => self.handle_project_init(req).await,
            methods::ROUTE_ADD => self.handle_route_add(req).await,
            methods::ROUTE_REMOVE => self.handle_route_remove(req).await,
            methods::ROUTE_LIST => self.handle_route_list(req.id).await,
            methods::DAEMON_SHUTDOWN => self.handle_daemon_shutdown(req.id).await,
            _ => Response::error(
                req.id,
                messages::METHOD_NOT_FOUND,
                format!("unknown method: {}", req.method),
            ),
        }
    }

    async fn handle_daemon_status(&self, id: u64) -> Response {
        Response::success(
            id,
            serde_json::json!({
                "version": env!("CARGO_PKG_VERSION"),
                "status": "running",
                "tld": self.tld,
            }),
        )
    }

    async fn handle_project_status(&self, id: u64) -> Response {
        // Clone data out of locks before serializing
        let project_data = self.projects.read().await.list();
        let route_data = self.router.read().await.list_routes();

        let project_list: Vec<serde_json::Value> = project_data
            .iter()
            .map(|(dir, name)| {
                serde_json::json!({
                    "name": name,
                    "directory": dir.to_string_lossy(),
                })
            })
            .collect();

        let route_list: Vec<serde_json::Value> = route_data
            .iter()
            .map(|(hostname, addr)| {
                serde_json::json!({
                    "hostname": hostname,
                    "upstream": addr.to_string(),
                })
            })
            .collect();

        Response::success(
            id,
            serde_json::json!({
                "projects": project_list,
                "routes": route_list,
            }),
        )
    }

    async fn handle_project_init(&self, req: &messages::Request) -> Response {
        let name = req.params.get("name").and_then(|v| v.as_str());
        let directory = req.params.get("directory").and_then(|v| v.as_str());

        let (name, directory) = match (name, directory) {
            (Some(n), Some(d)) => (n.to_string(), PathBuf::from(d)),
            _ => {
                return Response::error(
                    req.id,
                    messages::INVALID_PARAMS,
                    "missing 'name' or 'directory' param".into(),
                );
            }
        };

        if !validation::is_valid_dns_label(&name) {
            return Response::error(
                req.id,
                messages::INVALID_PARAMS,
                format!("invalid project name '{}': must be a valid DNS label (lowercase alphanumeric and hyphens, 1-63 chars)", name),
            );
        }

        self.projects
            .write()
            .await
            .register(directory.clone(), name.clone());

        Response::success(
            req.id,
            serde_json::json!({
                "name": name,
                "directory": directory.to_string_lossy(),
                "hostname": format!("{}.{}", name, self.tld),
            }),
        )
    }

    async fn handle_route_add(&self, req: &messages::Request) -> Response {
        let hostname = req.params.get("hostname").and_then(|v| v.as_str());
        let upstream = req.params.get("upstream").and_then(|v| v.as_str());

        let (hostname, upstream) = match (hostname, upstream) {
            (Some(h), Some(u)) => (h.to_string(), u.to_string()),
            _ => {
                return Response::error(
                    req.id,
                    messages::INVALID_PARAMS,
                    "missing 'hostname' or 'upstream' param".into(),
                );
            }
        };

        if !validation::is_valid_hostname(&hostname) {
            return Response::error(
                req.id,
                messages::INVALID_PARAMS,
                format!("invalid hostname '{}': must be a valid DNS name", hostname),
            );
        }

        let addr: SocketAddr = match upstream.parse() {
            Ok(a) => a,
            Err(e) => {
                return Response::error(
                    req.id,
                    messages::INVALID_PARAMS,
                    format!("invalid upstream address: {}", e),
                );
            }
        };

        self.router.write().await.add_route(hostname.clone(), addr);
        Response::success(req.id, serde_json::json!({"added": hostname}))
    }

    async fn handle_route_remove(&self, req: &messages::Request) -> Response {
        let hostname = match req.params.get("hostname").and_then(|v| v.as_str()) {
            Some(h) => h.to_string(),
            None => {
                return Response::error(
                    req.id,
                    messages::INVALID_PARAMS,
                    "missing 'hostname' param".into(),
                );
            }
        };

        let removed = self.router.write().await.remove_route(&hostname);
        Response::success(req.id, serde_json::json!({"removed": removed}))
    }

    async fn handle_route_list(&self, id: u64) -> Response {
        let route_data = self.router.read().await.list_routes();
        let list: Vec<serde_json::Value> = route_data
            .iter()
            .map(|(hostname, addr)| {
                serde_json::json!({
                    "hostname": hostname,
                    "upstream": addr.to_string(),
                })
            })
            .collect();

        Response::success(id, serde_json::json!({"routes": list}))
    }

    async fn handle_daemon_shutdown(&self, id: u64) -> Response {
        tracing::info!("shutdown requested via IPC");
        let _ = self.shutdown_tx.send(true);
        Response::success(id, serde_json::json!({"status": "shutting_down"}))
    }
}
