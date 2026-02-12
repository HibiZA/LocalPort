use crate::client::IpcClient;
use devspace_core::config::GlobalConfig;
use devspace_proto::methods;

pub async fn run(foreground: bool) -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;
    let config_path = cwd.join(".devspace.toml");

    if !config_path.exists() {
        anyhow::bail!(
            "no .devspace.toml found in {}\nRun `devspace init` first.",
            cwd.display()
        );
    }

    let global_config = GlobalConfig::load()
        .map_err(|e| anyhow::anyhow!("{}", e))?;
    let socket_path = global_config.socket_path();

    // Check if daemon is running
    if !socket_path.exists() {
        if foreground {
            // Start daemon in foreground (this blocks)
            println!("  Starting daemon in foreground...");
            return run_daemon(true).await;
        } else {
            // Start daemon in background
            println!("  Starting daemon...");
            start_daemon_background()?;
            // Give it a moment to start
            tokio::time::sleep(tokio::time::Duration::from_millis(500)).await;
        }
    }

    // Connect to daemon and start project
    let mut client = IpcClient::connect(&socket_path).await?;

    let resp = client
        .call(
            methods::PROJECT_UP,
            serde_json::json!({
                "directory": cwd.to_string_lossy(),
            }),
        )
        .await?;

    if let Some(error) = resp.error {
        anyhow::bail!("failed to start project: {}", error.message);
    }

    if let Some(result) = resp.result {
        let project = result.get("project").and_then(|v| v.as_str()).unwrap_or("?");
        println!("  Project '{}' started", project);

        if let Some(pid) = result.get("dev_pid") {
            let cmd = result
                .get("dev_command")
                .and_then(|v| v.as_str())
                .unwrap_or("?");
            println!("  dev server: {} (pid {})", cmd, pid);
        }

        println!("  hostname:   {}.localhost", project);
        println!(
            "  proxy:      http://{}:{}",
            global_config.proxy.bind_address, global_config.proxy.http_port
        );
    }

    Ok(())
}

pub async fn run_daemon(foreground: bool) -> anyhow::Result<()> {
    if foreground {
        // Run daemon directly in this process
        let config = GlobalConfig::load()
            .map_err(|e| anyhow::anyhow!("{}", e))?;

        tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(&config.daemon.log_level)),
            )
            .init();

        // We can't directly call daemon::Daemon::run here since it's in another crate.
        // Instead, exec the daemon binary.
        let status = std::process::Command::new("devspaced")
            .status()?;

        if !status.success() {
            anyhow::bail!("daemon exited with {}", status);
        }
        Ok(())
    } else {
        start_daemon_background()?;
        println!("  Daemon started");
        Ok(())
    }
}

fn start_daemon_background() -> anyhow::Result<()> {
    // Find the devspaced binary (same directory as devspace CLI, or on PATH)
    let devspaced = which_devspaced()?;

    std::process::Command::new(devspaced)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;

    Ok(())
}

fn which_devspaced() -> anyhow::Result<std::path::PathBuf> {
    // First check next to our own binary
    if let Ok(exe) = std::env::current_exe() {
        let sibling = exe.parent().unwrap().join("devspaced");
        if sibling.exists() {
            return Ok(sibling);
        }
    }

    // Fall back to PATH
    which::which("devspaced").map_err(|_| {
        anyhow::anyhow!("could not find 'devspaced' binary. Build it with `cargo build`.")
    })
}
