use crate::port_watcher::ProjectRegistry;
use crate::router::Router;
use localport_core::{config, validation};
use localport_proto::messages::{self, Response};
use localport_proto::methods;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{watch, Notify, RwLock};

pub struct IpcServer {
    socket_path: PathBuf,
    router: Arc<RwLock<Router>>,
    projects: Arc<RwLock<ProjectRegistry>>,
    tld: String,
    shutdown_tx: watch::Sender<bool>,
    scan_notify: Arc<Notify>,
}

impl IpcServer {
    pub fn new(
        socket_path: PathBuf,
        router: Arc<RwLock<Router>>,
        projects: Arc<RwLock<ProjectRegistry>>,
        tld: String,
        shutdown_tx: watch::Sender<bool>,
        scan_notify: Arc<Notify>,
    ) -> Self {
        Self {
            socket_path,
            router,
            projects,
            tld,
            shutdown_tx,
            scan_notify,
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
                        scan_notify: self.scan_notify.clone(),
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
    scan_notify: Arc<Notify>,
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
            methods::PROJECT_INIT | "project.register" => self.handle_project_init(req).await,
            methods::PROJECT_REMOVE => self.handle_project_remove(req).await,
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
        let directory = req
            .params
            .get("directory")
            .or_else(|| req.params.get("dir"))
            .and_then(|v| v.as_str());

        let directory = match directory {
            Some(d) => PathBuf::from(d),
            None => {
                return Response::error(
                    req.id,
                    messages::INVALID_PARAMS,
                    "missing 'directory' param".into(),
                );
            }
        };

        // Resolve name: explicit param > .localport.toml > directory basename
        let explicit_name = req.params.get("name").and_then(|v| v.as_str());
        let (raw_name, hostname_override) = if let Some(n) = explicit_name {
            (n.to_string(), None)
        } else {
            match config::load_project_config(&directory) {
                Ok(cfg) => (cfg.project.name.clone(), cfg.project.hostname.clone()),
                Err(_) => {
                    let fallback = directory
                        .file_name()
                        .map(|f| f.to_string_lossy().to_string())
                        .unwrap_or_else(|| "unnamed".to_string());
                    (fallback, None)
                }
            }
        };

        // Normalize: lowercase and replace underscores with hyphens so that
        // directory names like "grid_businessProductCalc" become valid DNS
        // labels ("grid-businessproductcalc") automatically.
        let name = raw_name.to_lowercase().replace('_', "-");

        if !validation::is_valid_dns_label(&name) {
            return Response::error(
                req.id,
                messages::INVALID_PARAMS,
                format!("invalid project name '{}': must be a valid DNS label (lowercase alphanumeric and hyphens, 1-63 chars)", name),
            );
        }

        // Register (or update) the project. If the same directory is already
        // registered, this overwrites the old entry — no duplicates.
        self.projects
            .write()
            .await
            .register(directory.clone(), name.clone());

        let hostname = hostname_override
            .unwrap_or_else(|| format!("{}.{}", name, self.tld));

        // Trigger an immediate port scan so already-running processes in this
        // directory are picked up without waiting for the next 2-second tick.
        self.scan_notify.notify_one();

        Response::success(
            req.id,
            serde_json::json!({
                "name": name,
                "directory": directory.to_string_lossy(),
                "hostname": hostname,
            }),
        )
    }

    async fn handle_project_remove(&self, req: &messages::Request) -> Response {
        let directory = req
            .params
            .get("directory")
            .or_else(|| req.params.get("dir"))
            .and_then(|v| v.as_str());

        let directory = match directory {
            Some(d) => std::path::PathBuf::from(d),
            None => {
                return Response::error(
                    req.id,
                    messages::INVALID_PARAMS,
                    "missing 'directory' param".into(),
                );
            }
        };

        // Look up the project name before removing, so we can clean up its routes.
        let project_name = self
            .projects
            .read()
            .await
            .find_project_for_dir(&directory)
            .map(|s| s.to_string());

        let removed = self.projects.write().await.unregister(&directory);

        if removed {
            // Remove routes that belonged to this project.
            if let Some(name) = &project_name {
                let hostname = format!("{}.{}", name, self.tld);
                self.router.write().await.remove_route(&hostname);
                tracing::info!("removed route {} and unregistered project at {}", hostname, directory.display());
            }

            // Trigger an immediate scan to reconcile state.
            self.scan_notify.notify_one();
        }

        Response::success(
            req.id,
            serde_json::json!({ "removed": removed }),
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
