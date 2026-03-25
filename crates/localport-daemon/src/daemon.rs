use crate::caddy::CaddyManager;
use crate::dns::DnsResponder;
use crate::ipc::IpcServer;
use crate::port_watcher::{PortWatcher, ProjectRegistry};
use crate::router::Router;
use localport_core::config::GlobalConfig;
use std::sync::Arc;
use tokio::signal;
use tokio::sync::{watch, Notify, RwLock};
use tokio::time::Duration;

pub struct Daemon;

impl Daemon {
    pub async fn run(config: GlobalConfig) -> anyhow::Result<()> {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let route_notify = Arc::new(Notify::new());

        // Shared state
        let router = Arc::new(RwLock::new(Router::new(route_notify.clone())));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));

        // Start Caddy
        let caddy = Arc::new(tokio::sync::Mutex::new(CaddyManager::new(
            config.clone(),
            router.clone(),
        )));
        caddy.lock().await.start().await?;

        // Route change listener: debounce and reload Caddy
        let caddy_for_reload = caddy.clone();
        let notify_for_reload = route_notify.clone();
        let mut reload_shutdown = shutdown_rx.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = notify_for_reload.notified() => {
                        // Debounce: wait for rapid batch changes to settle
                        tokio::time::sleep(Duration::from_millis(200)).await;
                        if let Err(e) = caddy_for_reload.lock().await.reload().await {
                            tracing::error!("caddy reload failed: {}", e);
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

        // Start port watcher
        let scan_notify = Arc::new(Notify::new());
        let port_watcher = PortWatcher::new(
            router.clone(),
            projects.clone(),
            config.tld.clone(),
            scan_notify.clone(),
        );
        let pw_shutdown = shutdown_rx.clone();
        let pw_handle = tokio::spawn(async move {
            port_watcher.run(pw_shutdown).await;
        });

        // Start IPC server
        let socket_path = config.socket_path();
        let ipc = IpcServer::new(
            socket_path.clone(),
            router.clone(),
            projects.clone(),
            config.tld.clone(),
            shutdown_tx.clone(),
            scan_notify.clone(),
        );
        let ipc_shutdown = shutdown_rx.clone();
        let ipc_handle = tokio::spawn(async move {
            if let Err(e) = ipc.run(ipc_shutdown).await {
                tracing::error!("IPC error: {}", e);
            }
        });

        tracing::info!("localportd is running (socket: {})", socket_path.display());

        // Wait for shutdown signal (Ctrl+C or IPC shutdown request)
        let mut shutdown_wait = shutdown_rx.clone();
        tokio::select! {
            _ = signal::ctrl_c() => {
                tracing::info!("received Ctrl+C");
                let _ = shutdown_tx.send(true);
            }
            _ = shutdown_wait.changed() => {
                tracing::info!("shutdown requested via IPC");
            }
        }

        // Stop Caddy
        caddy.lock().await.stop().await;

        // Wait for subsystems
        let _ = tokio::time::timeout(Duration::from_secs(5), async {
            let _ = pw_handle.await;
            let _ = ipc_handle.await;
        })
        .await;

        tracing::info!("localportd stopped");
        Ok(())
    }
}
