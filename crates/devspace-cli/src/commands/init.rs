use devspace_core::config::GlobalConfig;
use devspace_core::types::{ProjectConfig, ProjectSection};
use std::path::PathBuf;

pub async fn run(name: Option<String>) -> anyhow::Result<()> {
    let config = GlobalConfig::load().unwrap_or_default();
    let tld = &config.tld;
    let cwd = std::env::current_dir()?;

    let project_name = name.unwrap_or_else(|| {
        cwd.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("project")
            .to_string()
    });

    // Slugify the name for hostname use
    let hostname = slugify(&project_name)?;

    let config_path = cwd.join(".devspace.toml");
    if config_path.exists() {
        println!("  .devspace.toml already exists in {}", cwd.display());
        println!("  project: {}", read_existing_name(&config_path)?);
        return Ok(());
    }

    // Use proper TOML serialization to prevent injection
    let project_config = ProjectConfig {
        project: ProjectSection {
            name: project_name.clone(),
            hostname: Some(hostname.clone()),
        },
    };
    let config_content = toml::to_string_pretty(&project_config)?;

    std::fs::write(&config_path, &config_content)?;

    println!("  Initialized DevSpace project");
    println!("  name:     {}", project_name);
    println!("  hostname: {}.{}", hostname, tld);
    println!("  config:   {}", config_path.display());

    Ok(())
}

fn slugify(name: &str) -> anyhow::Result<String> {
    let result: String = name
        .to_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string();

    if result.is_empty() {
        anyhow::bail!("project name must contain at least one alphanumeric character");
    }
    if result.len() > 63 {
        anyhow::bail!("project hostname too long (max 63 chars)");
    }

    Ok(result)
}

fn read_existing_name(path: &PathBuf) -> anyhow::Result<String> {
    let content = std::fs::read_to_string(path)?;
    let config: ProjectConfig = toml::from_str(&content)?;
    Ok(config.project.name)
}
