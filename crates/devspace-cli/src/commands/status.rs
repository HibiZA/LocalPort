use crate::client::IpcClient;
use devspace_core::config::GlobalConfig;
use devspace_core::validation::LOCALHOST_TLD;
use devspace_proto::methods;

pub async fn run() -> anyhow::Result<()> {
    let config = GlobalConfig::load().map_err(|e| anyhow::anyhow!("{}", e))?;
    let socket_path = config.socket_path();

    let mut client = IpcClient::connect(&socket_path).await?;

    let resp = client
        .call(methods::PROJECT_STATUS, serde_json::json!({}))
        .await?;

    if let Some(error) = resp.error {
        anyhow::bail!("{}", error.message);
    }

    let result = resp.result.unwrap_or_default();

    // Projects
    let projects = result
        .get("projects")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if projects.is_empty() {
        println!("  No projects registered.");
        println!("  Run `devspace init` in a project directory.");
    } else {
        println!("  PROJECTS");
        println!("  {:<20} {}", "NAME", "DIRECTORY");
        for p in &projects {
            let name = p.get("name").and_then(|v| v.as_str()).unwrap_or("?");
            let dir = p.get("directory").and_then(|v| v.as_str()).unwrap_or("?");
            println!("  {:<20} {}", name, dir);
        }
    }

    // Routes
    let routes = result
        .get("routes")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if !routes.is_empty() {
        println!();
        println!("  ROUTES");
        println!("  {:<35} {}", "HOSTNAME", "UPSTREAM");
        for r in &routes {
            let hostname = r.get("hostname").and_then(|v| v.as_str()).unwrap_or("?");
            let upstream = r.get("upstream").and_then(|v| v.as_str()).unwrap_or("?");
            println!("  {:<35} {}", hostname, upstream);
        }
    }

    Ok(())
}

pub async fn daemon_status() -> anyhow::Result<()> {
    let config = GlobalConfig::load().map_err(|e| anyhow::anyhow!("{}", e))?;
    let socket_path = config.socket_path();

    let mut client = IpcClient::connect(&socket_path).await?;

    let resp = client
        .call(methods::DAEMON_STATUS, serde_json::json!({}))
        .await?;

    if let Some(error) = resp.error {
        anyhow::bail!("{}", error.message);
    }

    let result = resp.result.unwrap_or_default();
    let version = result
        .get("version")
        .and_then(|v| v.as_str())
        .unwrap_or("?");
    let status = result.get("status").and_then(|v| v.as_str()).unwrap_or("?");

    let tld = result.get("tld").and_then(|v| v.as_str()).unwrap_or("?");

    println!("  daemon version: {}", version);
    println!("  status:         {}", status);
    println!("  tld:            .{}", tld);
    println!("  socket:         {}", socket_path.display());

    if tld != LOCALHOST_TLD {
        println!(
            "  proxy:          Caddy (HTTPS:{}, HTTP:{})",
            config.caddy.https_port, config.caddy.http_port
        );
        println!("  dns:            127.0.0.1:{}", config.daemon.dns_port);
    } else {
        println!("  proxy:          Caddy (HTTP:{})", config.caddy.http_port);
    }

    Ok(())
}

pub async fn start_daemon(foreground: bool) -> anyhow::Result<()> {
    if foreground {
        let status = std::process::Command::new("devspaced").status()?;

        if !status.success() {
            anyhow::bail!("daemon exited with {}", status);
        }
        Ok(())
    } else {
        let devspaced = which_devspaced()?;

        std::process::Command::new(devspaced)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()?;

        println!("  Daemon started");
        Ok(())
    }
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

fn which_devspaced() -> anyhow::Result<std::path::PathBuf> {
    if let Ok(exe) = std::env::current_exe() {
        let sibling = exe.parent().unwrap().join("devspaced");
        if sibling.exists() {
            return Ok(sibling);
        }
    }

    which::which("devspaced").map_err(|_| {
        anyhow::anyhow!("could not find 'devspaced' binary. Build it with `cargo build`.")
    })
}
