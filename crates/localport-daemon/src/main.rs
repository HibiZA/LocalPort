mod caddy;
mod daemon;
mod dns;
mod ipc;
mod port_watcher;
mod router;

use anyhow::Result;
use std::io::IsTerminal;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    let config = localport_core::config::GlobalConfig::load()
        .map_err(|e| anyhow::anyhow!("failed to load config: {}", e))?;

    // RUST_LOG wins; otherwise use the configured level. Logs go to stderr,
    // which the app redirects to ~/Library/Logs/LocalPort/localportd.log.
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(&config.daemon.log_level));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_ansi(std::io::stderr().is_terminal())
        .init();

    tracing::info!(
        "localportd {} starting (tld: .{})",
        localport_core::VERSION,
        config.tld
    );

    daemon::Daemon::run(config).await
}
