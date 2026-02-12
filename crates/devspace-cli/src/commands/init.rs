use devspace_core::types::ProjectConfig;
use std::path::PathBuf;

pub async fn run(name: Option<String>) -> anyhow::Result<()> {
    let cwd = std::env::current_dir()?;

    let project_name = name.unwrap_or_else(|| {
        cwd.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("project")
            .to_string()
    });

    // Slugify the name for hostname use
    let hostname = slugify(&project_name);

    let config_path = cwd.join(".devspace.toml");
    if config_path.exists() {
        println!("  .devspace.toml already exists in {}", cwd.display());
        println!("  project: {}", read_existing_name(&config_path)?);
        return Ok(());
    }

    let config_content = format!(
        r#"[project]
name = "{name}"
hostname = "{hostname}"

[dev]
# command = "npm run dev"
# port = 3000

[editor]
type = "auto"
"#,
        name = project_name,
        hostname = hostname,
    );

    std::fs::write(&config_path, &config_content)?;

    println!("  Initialized DevSpace project");
    println!("  name:     {}", project_name);
    println!("  hostname: {}.localhost", hostname);
    println!("  config:   {}", config_path.display());
    println!();
    println!("  Edit .devspace.toml to configure your dev server command,");
    println!("  then run `devspace up` to start.");

    Ok(())
}

fn slugify(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' { c } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn read_existing_name(path: &PathBuf) -> anyhow::Result<String> {
    let content = std::fs::read_to_string(path)?;
    let config: ProjectConfig = toml::from_str(&content)?;
    Ok(config.project.name)
}
