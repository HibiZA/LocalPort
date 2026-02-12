use crate::ipc::IpcServer;
use crate::port_watcher::{PortWatcher, ProjectRegistry};
use crate::process_manager::ProcessManager;
use crate::proxy::ProxyServer;
use crate::router::Router;
use devspace_core::config::GlobalConfig;
use std::sync::Arc;
use tokio::signal;
use tokio::sync::{watch, Mutex, RwLock};

pub struct Daemon;

impl Daemon {
    pub async fn run(config: GlobalConfig) -> anyhow::Result<()> {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        // Shared state
        let router = Arc::new(RwLock::new(Router::new()));
        let projects = Arc::new(RwLock::new(ProjectRegistry::default()));
        let process_manager = Arc::new(Mutex::new(ProcessManager::new()));

        // Start reverse proxy
        let bind_addr = format!("{}:{}", config.proxy.bind_address, config.proxy.http_port)
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid bind address: {}", e))?;

        let proxy = ProxyServer::new(bind_addr, router.clone());
        let proxy_shutdown = shutdown_rx.clone();
        let proxy_handle = tokio::spawn(async move {
            if let Err(e) = proxy.run(proxy_shutdown).await {
                tracing::error!("proxy error: {}", e);
            }
        });

        // Start port watcher
        let port_watcher = PortWatcher::new(router.clone(), projects.clone());
        let pw_shutdown = shutdown_rx.clone();
        let pw_handle = tokio::spawn(async move {
            port_watcher.run(pw_shutdown).await;
        });

        // Start IPC server
        let socket_path = config.socket_path();
        let ipc = IpcServer::new(
            socket_path.clone(),
            router.clone(),
            process_manager.clone(),
            projects.clone(),
        );
        let ipc_shutdown = shutdown_rx.clone();
        let ipc_handle = tokio::spawn(async move {
            if let Err(e) = ipc.run(ipc_shutdown).await {
                tracing::error!("IPC error: {}", e);
            }
        });

        tracing::info!("devspaced is running (socket: {})", socket_path.display());

        // Wait for shutdown signal
        signal::ctrl_c().await?;
        tracing::info!("received shutdown signal");

        // Signal all subsystems to stop
        let _ = shutdown_tx.send(true);

        // Stop all managed processes
        process_manager.lock().await.stop_all().await;

        // Wait for subsystems
        let _ = tokio::time::timeout(
            tokio::time::Duration::from_secs(5),
            async {
                let _ = proxy_handle.await;
                let _ = pw_handle.await;
                let _ = ipc_handle.await;
            },
        )
        .await;

        tracing::info!("devspaced stopped");
        Ok(())
    }
}
