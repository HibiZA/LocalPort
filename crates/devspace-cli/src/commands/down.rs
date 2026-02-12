use crate::client::IpcClient;
use devspace_core::config::GlobalConfig;
use devspace_proto::methods;

pub async fn run() -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let config_path = cwd.join(".devspace.toml");

    if !config_path.exists() {
        anyhow::bail!("no .devspace.toml found in {}", cwd.display());
    }

    let project_config = devspace_core::config::load_project_config(&cwd)
        .map_err(|e| anyhow::anyhow!("{}", e))?;

    let global_config = GlobalConfig::load().map_err(|e| anyhow::anyhow!("{}", e))?;
    let socket_path = global_config.socket_path();

    let mut client = IpcClient::connect(&socket_path).await?;

    let resp = client
        .call(
            methods::PROJECT_DOWN,
            serde_json::json!({
                "name": project_config.project.name,
            }),
        )
        .await?;

    if let Some(error) = resp.error {
        anyhow::bail!("{}", error.message);
    }

    println!("  Project '{}' stopped", project_config.project.name);
    Ok(())
}

pub async fn stop_daemon() -> anyhow::Result<()> {
    let config = GlobalConfig::load().map_err(|e| anyhow::anyhow!("{}", e))?;
    let socket_path = config.socket_path();

    let mut client = IpcClient::connect(&socket_path).await?;

    let resp = client
        .call(methods::DAEMON_SHUTDOWN, serde_json::json!({}))
        .await?;

    if let Some(error) = resp.error {
        anyhow::bail!("{}", error.message);
    }

    println!("  Daemon shutdown requested");
    Ok(())
}
