use crate::caddy::CaddyManager;
use crate::port_watcher::{ProjectEntry, ProjectRegistry, WatchSnapshot};
use crate::router::Router;
use localport_core::config::{self, GlobalConfig};
use localport_core::validation;
use localport_proto::messages::{self, Response};
use localport_proto::methods;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::{watch, Notify, RwLock};

/// Shared daemon state the IPC handlers read and mutate.
#[derive(Clone)]
pub struct IpcContext {
    pub config: GlobalConfig,
    pub router: Arc<RwLock<Router>>,
    pub projects: Arc<RwLock<ProjectRegistry>>,
    /// Route owners and unclaimed ports from the watcher's last scan.
    pub snapshot: Arc<RwLock<WatchSnapshot>>,
    pub caddy: Arc<CaddyManager>,
    pub shutdown_tx: watch::Sender<bool>,
    /// Wakes the port watcher so registry changes apply immediately.
    pub scan_notify: Arc<Notify>,
}

pub struct IpcServer {
    socket_path: PathBuf,
    ctx: IpcContext,
}

impl IpcServer {
    pub fn new(socket_path: PathBuf, ctx: IpcContext) -> Self {
        Self { socket_path, ctx }
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
                    let handler = ConnectionHandler { ctx: self.ctx.clone() };
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
    ctx: IpcContext,
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
        let cfg = &self.ctx.config;
        Response::success(
            id,
            serde_json::json!({
                "version": localport_core::VERSION,
                "status": "running",
                "tld": cfg.tld,
                "http_port": cfg.caddy.http_port,
                "https_port": cfg.caddy.https_port,
                "dns_port": cfg.daemon.dns_port,
                "proxy": self.ctx.caddy.status(),
                "ca_root": GlobalConfig::ca_root_path().to_string_lossy(),
                "log_dir": GlobalConfig::log_dir().to_string_lossy(),
            }),
        )
    }

    async fn handle_project_status(&self, id: u64) -> Response {
        // Clone data out of locks before serializing
        let mut project_data = self.ctx.projects.read().await.list();
        project_data.sort_by(|a, b| a.1.name.cmp(&b.1.name));
        let snapshot = self.ctx.snapshot.read().await.clone();
        let router = self.ctx.router.read().await;
        let route_data = router.list_routes();

        let project_list: Vec<serde_json::Value> = project_data
            .iter()
            .map(|(dir, entry)| {
                let upstream = router.get(&entry.hostname);
                serde_json::json!({
                    "name": entry.name,
                    "directory": dir.to_string_lossy(),
                    "hostname": entry.hostname,
                    "port": entry.port,
                    "claim": entry.claim,
                    "upstream": upstream.map(|a| a.to_string()),
                    "owner": upstream.and(snapshot.owners.get(&entry.hostname)),
                })
            })
            .collect();

        let route_list: Vec<serde_json::Value> = route_data
            .iter()
            .map(|(hostname, addr)| {
                serde_json::json!({
                    "hostname": hostname,
                    "upstream": addr.to_string(),
                    "owner": snapshot.owners.get(hostname),
                })
            })
            .collect();

        Response::success(
            id,
            serde_json::json!({
                "projects": project_list,
                "routes": route_list,
                "unclaimed": snapshot.unclaimed,
            }),
        )
    }

    /// Register (or re-register) a project directory.
    ///
    /// Each setting resolves independently: explicit param > `.localport.toml`
    /// > default (directory basename / `<name>.<tld>` / no pinned port).
    async fn handle_project_init(&self, req: &messages::Request) -> Response {
        let Some(directory) = directory_param(req) else {
            return invalid_params(req.id, "missing 'directory' param");
        };

        let file = config::load_project_config(&directory)
            .ok()
            .map(|c| c.project);
        let non_empty = |s: &str| (!s.trim().is_empty()).then(|| s.to_string());

        let raw_name = str_param(req, "name")
            .and_then(non_empty)
            .or_else(|| file.as_ref().and_then(|f| non_empty(&f.name)))
            .unwrap_or_else(|| {
                directory
                    .file_name()
                    .map(|f| f.to_string_lossy().to_string())
                    .unwrap_or_else(|| "unnamed".to_string())
            });

        // Normalize: lowercase and replace underscores with hyphens so that
        // directory names like "grid_businessProductCalc" become valid DNS
        // labels ("grid-businessproductcalc") automatically.
        let name = validation::normalize_project_name(&raw_name);
        if !validation::is_valid_dns_label(&name) {
            return invalid_params(
                req.id,
                &format!("invalid project name '{name}': must be a valid DNS label (lowercase alphanumeric and hyphens, 1-63 chars)"),
            );
        }

        let tld = &self.ctx.config.tld;
        let hostname = match str_param(req, "hostname")
            .and_then(non_empty)
            .or_else(|| file.as_ref().and_then(|f| f.hostname.clone()))
        {
            Some(raw) => match validation::qualify_hostname(&raw, tld) {
                Some(h) => h,
                None => {
                    return invalid_params(req.id, &format!("invalid hostname '{raw}'"));
                }
            },
            None => format!("{name}.{tld}"),
        };

        let port = match req.params.get("port") {
            None | Some(serde_json::Value::Null) => file.as_ref().and_then(|f| f.port),
            Some(v) => match v
                .as_u64()
                .and_then(|p| u16::try_from(p).ok())
                .filter(|&p| p > 0)
            {
                Some(p) => Some(p),
                None => return invalid_params(req.id, "invalid 'port' param"),
            },
        };

        // Claiming routes the pinned port whoever listens on it, so it is
        // only accepted together with a port.
        let claim = req
            .params
            .get("claim")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if claim && port.is_none() {
            return invalid_params(req.id, "'claim' requires a 'port'");
        }

        let entry = ProjectEntry {
            name,
            hostname,
            port,
            claim,
        };

        // Register (or update) the project. If the same directory is already
        // registered, this overwrites the old entry — no duplicates.
        self.ctx
            .projects
            .write()
            .await
            .register(directory.clone(), entry.clone());

        // Scan now so already-running servers are routed immediately.
        self.ctx.scan_notify.notify_one();

        Response::success(
            req.id,
            serde_json::json!({
                "name": entry.name,
                "directory": directory.to_string_lossy(),
                "hostname": entry.hostname,
                "port": entry.port,
                "claim": entry.claim,
            }),
        )
    }

    async fn handle_project_remove(&self, req: &messages::Request) -> Response {
        let Some(directory) = directory_param(req) else {
            return invalid_params(req.id, "missing 'directory' param");
        };

        let removed = self.ctx.projects.write().await.unregister(&directory);
        if let Some(entry) = &removed {
            tracing::info!(
                "unregistered project '{}' at {}",
                entry.name,
                directory.display()
            );
            // The watcher removes the project's route on this scan.
            self.ctx.scan_notify.notify_one();
        }

        Response::success(req.id, serde_json::json!({ "removed": removed.is_some() }))
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

        self.ctx
            .router
            .write()
            .await
            .add_route(hostname.clone(), addr);
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

        let removed = self.ctx.router.write().await.remove_route(&hostname);
        Response::success(req.id, serde_json::json!({"removed": removed}))
    }

    async fn handle_route_list(&self, id: u64) -> Response {
        let route_data = self.ctx.router.read().await.list_routes();
        Response::success(id, serde_json::json!({"routes": routes_json(&route_data)}))
    }

    async fn handle_daemon_shutdown(&self, id: u64) -> Response {
        tracing::info!("shutdown requested via IPC");
        let _ = self.ctx.shutdown_tx.send(true);
        Response::success(id, serde_json::json!({"status": "shutting_down"}))
    }
}

fn routes_json(routes: &[(String, SocketAddr)]) -> Vec<serde_json::Value> {
    routes
        .iter()
        .map(|(hostname, addr)| {
            serde_json::json!({
                "hostname": hostname,
                "upstream": addr.to_string(),
            })
        })
        .collect()
}

fn str_param<'a>(req: &'a messages::Request, key: &str) -> Option<&'a str> {
    req.params.get(key).and_then(|v| v.as_str())
}

/// The `directory` param (`dir` is accepted as an alias).
fn directory_param(req: &messages::Request) -> Option<PathBuf> {
    str_param(req, "directory")
        .or_else(|| str_param(req, "dir"))
        .map(PathBuf::from)
}

fn invalid_params(id: u64, message: &str) -> Response {
    Response::error(id, messages::INVALID_PARAMS, message.to_string())
}
