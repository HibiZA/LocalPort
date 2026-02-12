use crate::client::IpcClient;
use devspace_core::config::GlobalConfig;
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
        println!("  Run `devspace init` in a project directory, then `devspace up`.");
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

    // Processes
    let processes = result
        .get("processes")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if !processes.is_empty() {
        println!();
        println!("  PROCESSES");
        println!("  {:<20} {:<10} {:<10} {}", "PROJECT", "TYPE", "PID", "COMMAND");
        for p in &processes {
            let project = p.get("project_id").and_then(|v| v.as_str()).unwrap_or("?");
            let ptype = p
                .get("process_type")
                .and_then(|v| v.as_str())
                .unwrap_or("?");
            let pid = p.get("pid").and_then(|v| v.as_u64()).unwrap_or(0);
            let cmd = p.get("command").and_then(|v| v.as_str()).unwrap_or("?");
            println!("  {:<20} {:<10} {:<10} {}", project, ptype, pid, cmd);
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
    let version = result.get("version").and_then(|v| v.as_str()).unwrap_or("?");
    let status = result.get("status").and_then(|v| v.as_str()).unwrap_or("?");

    println!("  daemon version: {}", version);
    println!("  status:         {}", status);
    println!("  socket:         {}", socket_path.display());
    println!(
        "  proxy:          http://{}:{}",
        config.proxy.bind_address, config.proxy.http_port
    );

    if let Some(editor) = result.get("editor") {
        if !editor.is_null() {
            let name = editor.get("name").and_then(|v| v.as_str()).unwrap_or("?");
            let binary = editor.get("binary").and_then(|v| v.as_str()).unwrap_or("?");
            println!("  editor:         {} ({})", name, binary);
        } else {
            println!("  editor:         none detected");
        }
    }

    Ok(())
}
