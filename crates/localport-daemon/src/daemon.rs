use crate::caddy::CaddyManager;
use crate::dns::DnsResponder;
use crate::ipc::{IpcContext, IpcServer};
use crate::port_watcher::{PortWatcher, ProjectRegistry, WatchSnapshot};
use crate::router::Router;
use localport_core::config::GlobalConfig;
use std::collections::HashSet;
use std::sync::Arc;
use tokio::signal::unix::{signal, SignalKind};
use tokio::sync::{watch, Notify, RwLock};
use tokio::time::Duration;

pub struct Daemon;

impl Daemon {
    pub async fn run(config: GlobalConfig) -> anyhow::Result<()> {
        // Single instance: a live daemon answers on the socket. Starting a
        // second one would delete its socket and fight it for Caddy's ports.
        let socket_path = config.socket_path();
        if std::os::unix::net::UnixStream::connect(&socket_path).is_ok() {
            anyhow::bail!(
                "another localportd is already running (socket {})",
                socket_path.display()
            );
        }

        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let route_notify = Arc::new(Notify::new());

        // Shared state
        let router = Arc::new(RwLock::new(Router::new(route_notify.clone())));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
        let snapshot = Arc::new(RwLock::new(WatchSnapshot::default()));
        let caddy = Arc::new(CaddyManager::new(config.clone(), router.clone()));

        // Caddy runs under a supervisor in the background, so IPC comes up
        // immediately even while Caddy is downloading or failing to start.
        let caddy_handle = tokio::spawn(caddy.clone().supervise(shutdown_rx.clone()));

        // Route change listener: debounce and reload Caddy
        let caddy_for_reload = caddy.clone();
        let mut reload_shutdown = shutdown_rx.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = route_notify.notified() => {
                        // Debounce: wait for rapid batch changes to settle
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        if let Err(e) = caddy_for_reload.reload().await {
                            tracing::error!("caddy reload failed: {e:#}");
                        }
                    }
                    _ = reload_shutdown.changed() => break,
                }
            }
        });

        // Start DNS responder (only for non-localhost TLDs)
        if config.tld != localport_core::validation::LOCALHOST_TLD {
            let dns = DnsResponder::new(config.daemon.dns_port);
            let dns_shutdown = shutdown_rx.clone();
            tokio::spawn(async move {
                if let Err(e) = dns.run(dns_shutdown).await {
                    tracing::error!("DNS responder error: {}", e);
                }
            });
        }

        // Start port watcher. Caddy's own ports are never routed.
        let scan_notify = Arc::new(Notify::new());
        let excluded_ports = HashSet::from([
            config.caddy.http_port,
            config.caddy.https_port,
            config.caddy.admin_port,
        ]);
        let port_watcher = PortWatcher::new(
            router.clone(),
            projects.clone(),
            config.tld.clone(),
            scan_notify.clone(),
            excluded_ports,
            snapshot.clone(),
        );
        let pw_shutdown = shutdown_rx.clone();
        let pw_handle = tokio::spawn(async move {
            port_watcher.run(pw_shutdown).await;
        });

        // Start IPC server
        let ipc = IpcServer::new(
            socket_path.clone(),
            IpcContext {
                config: config.clone(),
                router: router.clone(),
                projects: projects.clone(),
                snapshot: snapshot.clone(),
                caddy: caddy.clone(),
                shutdown_tx: shutdown_tx.clone(),
                scan_notify: scan_notify.clone(),
            },
        );
        let ipc_shutdown = shutdown_rx.clone();
        let ipc_handle = tokio::spawn(async move {
            if let Err(e) = ipc.run(ipc_shutdown).await {
                tracing::error!("IPC error: {}", e);
            }
        });

        tracing::info!("localportd is running (socket: {})", socket_path.display());

        // Wait for SIGINT, SIGTERM (launchd, `kill`, logout) or an IPC
        // shutdown request — all of them stop Caddy cleanly.
        let mut sigterm = signal(SignalKind::terminate())?;
        let mut sigint = signal(SignalKind::interrupt())?;
        let mut shutdown_wait = shutdown_rx.clone();
        tokio::select! {
            _ = sigint.recv() => tracing::info!("received SIGINT"),
            _ = sigterm.recv() => tracing::info!("received SIGTERM"),
            _ = shutdown_wait.changed() => tracing::info!("shutdown requested via IPC"),
        }
        let _ = shutdown_tx.send(true);

        // Wait for subsystems (the Caddy supervisor stops Caddy on shutdown)
        let _ = tokio::time::timeout(Duration::from_secs(8), async {
            let _ = caddy_handle.await;
            let _ = pw_handle.await;
            let _ = ipc_handle.await;
        })
        .await;

        tracing::info!("localportd stopped");
        Ok(())
    }
}
