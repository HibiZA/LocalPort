mod daemon;
mod editor;
mod ipc;
mod port_watcher;
mod process_manager;
mod proxy;
mod router;

use anyhow::Result;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let config = devspace_core::config::GlobalConfig::load()
        .map_err(|e| anyhow::anyhow!("failed to load config: {}", e))?;

    tracing::info!(
        "devspaced starting on {}:{}",
        config.proxy.bind_address,
        config.proxy.http_port
    );

    daemon::Daemon::run(config).await
}
