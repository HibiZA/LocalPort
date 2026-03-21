use devspace_core::config::GlobalConfig;
use devspace_core::validation::LOCALHOST_TLD;

pub async fn run() -> anyhow::Result<()> {
    let config = GlobalConfig::load().unwrap_or_default();
    let caddy_bin = config.resolve_caddy_bin();

    println!("  DevSpace Setup");
    println!("  TLD: .{}", config.tld);
    println!();

    // Step 1: Check/install Caddy
    print!("  Checking Caddy... ");
    match check_caddy(&caddy_bin).await {
        Ok(version) => println!("found ({})", version.trim()),
        Err(_) => {
            println!("not found, downloading...");
            download_caddy().await?;
            let version = check_caddy(&config.resolve_caddy_bin()).await?;
            println!("  installed ({})", version.trim());
        }
    }

    let caddy_bin = config.resolve_caddy_bin();

    // Step 2: Install Caddy root CA (for HTTPS with internal certs)
    if config.tld != LOCALHOST_TLD {
        print!("  Installing Caddy root CA... ");
        let status = std::process::Command::new(&caddy_bin)
            .args(["trust"])
            .status();

        match status {
            Ok(s) if s.success() => println!("done"),
            _ => println!(
                "skipped (run `{} trust` manually if HTTPS doesn't work)",
                caddy_bin
            ),
        }
    }

    // Step 3: Create DNS resolver (only for non-localhost TLDs)
    if config.tld != LOCALHOST_TLD {
        println!("  Creating DNS resolver for .{}...", config.tld);

        let resolver_content = format!("nameserver 127.0.0.1\nport {}\n", config.daemon.dns_port);
        let resolver_path = format!("/etc/resolver/{}", config.tld);

        // This requires sudo
        let status = std::process::Command::new("sudo")
            .args(["mkdir", "-p", "/etc/resolver"])
            .status()?;

        if !status.success() {
            anyhow::bail!("failed to create /etc/resolver directory");
        }

        let status = std::process::Command::new("sudo")
            .args(["tee", &resolver_path])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                if let Some(ref mut stdin) = child.stdin {
                    stdin.write_all(resolver_content.as_bytes())?;
                }
                child.wait()
            })?;

        if status.success() {
            println!("    Created {}", resolver_path);
        } else {
            println!("    Failed to create resolver file. Create it manually:");
            println!("    sudo mkdir -p /etc/resolver");
            println!(
                "    echo '{}' | sudo tee {}",
                resolver_content.trim(),
                resolver_path
            );
        }
    }

    // Step 4: Set up pfctl port forwarding (80->http_port, 443->https_port)
    if config.tld != LOCALHOST_TLD {
        println!(
            "  Setting up port forwarding (80 -> {}, 443 -> {})...",
            config.caddy.http_port, config.caddy.https_port
        );

        let anchor_content = format!(
            "rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port {}\n\
             rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 443 -> 127.0.0.1 port {}\n",
            config.caddy.http_port, config.caddy.https_port
        );

        let anchor_path = "/etc/pf.anchors/devspace";

        let status = std::process::Command::new("sudo")
            .args(["tee", anchor_path])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                if let Some(ref mut stdin) = child.stdin {
                    stdin.write_all(anchor_content.as_bytes())?;
                }
                child.wait()
            })?;

        if status.success() {
            println!("    Created {}", anchor_path);

            // Load the anchor
            let _ = std::process::Command::new("sudo")
                .args(["pfctl", "-a", "devspace", "-f", anchor_path])
                .status();

            // Enable pf if not already enabled
            let _ = std::process::Command::new("sudo")
                .args(["pfctl", "-e"])
                .stderr(std::process::Stdio::null())
                .status();

            println!("    Port forwarding enabled");
        } else {
            println!("    Failed to set up port forwarding.");
            println!(
                "    You can access projects at https://myapp.{}:{} instead.",
                config.tld, config.caddy.https_port
            );
        }
    }

    // Summary
    println!();
    println!("  Setup complete!");
    println!();
    if config.tld != LOCALHOST_TLD {
        println!(
            "  DNS:       /etc/resolver/{} -> 127.0.0.1:{}",
            config.tld, config.daemon.dns_port
        );
        println!(
            "  Proxy:     Caddy (HTTP:{}, HTTPS:{})",
            config.caddy.http_port, config.caddy.https_port
        );
        println!(
            "  Ports:     80 -> {}, 443 -> {}",
            config.caddy.http_port, config.caddy.https_port
        );
    } else {
        println!("  Proxy:     Caddy (HTTP:{})", config.caddy.http_port);
        println!(
            "  Access:    http://myapp.localhost:{}",
            config.caddy.http_port
        );
    }
    println!();
    println!("  Start the daemon: devspace daemon start");

    Ok(())
}

async fn check_caddy(bin: &str) -> anyhow::Result<String> {
    let output = tokio::process::Command::new(bin)
        .args(["version"])
        .output()
        .await
        .map_err(|_| anyhow::anyhow!("caddy not found"))?;

    if !output.status.success() {
        anyhow::bail!("caddy version check failed");
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

async fn download_caddy() -> anyhow::Result<()> {
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };

    let url = format!(
        "https://caddyserver.com/api/download?os=darwin&arch={}",
        arch
    );

    let bin_dir = GlobalConfig::config_dir().join("bin");
    std::fs::create_dir_all(&bin_dir)?;

    let bin_path = bin_dir.join("caddy");
    let tmp_path = bin_dir.join("caddy.tmp");

    println!("    Downloading from {}", url);

    let status = tokio::process::Command::new("curl")
        .args([
            "-fSL",
            "--progress-bar",
            "-o",
            &tmp_path.to_string_lossy(),
            &url,
        ])
        .status()
        .await?;

    if !status.success() {
        let _ = std::fs::remove_file(&tmp_path);
        anyhow::bail!("failed to download caddy");
    }

    // Make executable
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp_path, std::fs::Permissions::from_mode(0o755))?;
    }

    std::fs::rename(&tmp_path, &bin_path)?;
    println!("    Installed to {}", bin_path.display());

    Ok(())
}
