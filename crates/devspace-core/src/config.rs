use crate::error::DevSpaceError;
use crate::types::ProjectConfig;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Global daemon configuration (~/.config/devspace/config.toml)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalConfig {
    #[serde(default)]
    pub proxy: ProxyConfig,
    #[serde(default)]
    pub daemon: DaemonConfig,
    #[serde(default)]
    pub editor: GlobalEditorConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProxyConfig {
    #[serde(default = "default_http_port")]
    pub http_port: u16,
    #[serde(default = "default_bind_address")]
    pub bind_address: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonConfig {
    #[serde(default = "default_log_level")]
    pub log_level: String,
    #[serde(default)]
    pub socket_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalEditorConfig {
    #[serde(default = "default_preferred")]
    pub preferred: String,
    #[serde(default = "default_port_range")]
    pub port_range: (u16, u16),
}

fn default_http_port() -> u16 {
    8080
}

fn default_bind_address() -> String {
    "127.0.0.1".to_string()
}

fn default_log_level() -> String {
    "info".to_string()
}

fn default_preferred() -> String {
    "auto".to_string()
}

fn default_port_range() -> (u16, u16) {
    (4000, 4099)
}

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            proxy: ProxyConfig::default(),
            daemon: DaemonConfig::default(),
            editor: GlobalEditorConfig::default(),
        }
    }
}

impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            http_port: default_http_port(),
            bind_address: default_bind_address(),
        }
    }
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            log_level: default_log_level(),
            socket_path: None,
        }
    }
}

impl Default for GlobalEditorConfig {
    fn default() -> Self {
        Self {
            preferred: default_preferred(),
            port_range: default_port_range(),
        }
    }
}

impl GlobalConfig {
    pub fn load() -> Result<Self, DevSpaceError> {
        let path = global_config_path();
        if path.exists() {
            let content = std::fs::read_to_string(&path).map_err(DevSpaceError::Io)?;
            toml::from_str(&content)
                .map_err(|e| DevSpaceError::Config(format!("failed to parse {}: {}", path.display(), e)))
        } else {
            Ok(Self::default())
        }
    }

    pub fn socket_path(&self) -> PathBuf {
        if let Some(ref p) = self.daemon.socket_path {
            PathBuf::from(p)
        } else {
            default_socket_path()
        }
    }
}

pub fn load_project_config(dir: &Path) -> Result<ProjectConfig, DevSpaceError> {
    let config_path = dir.join(".devspace.toml");
    if !config_path.exists() {
        return Err(DevSpaceError::Config(format!(
            "no .devspace.toml found in {}",
            dir.display()
        )));
    }
    let content = std::fs::read_to_string(&config_path).map_err(DevSpaceError::Io)?;
    toml::from_str(&content)
        .map_err(|e| DevSpaceError::Config(format!("failed to parse .devspace.toml: {}", e)))
}

pub fn global_config_path() -> PathBuf {
    dirs_path("config").join("devspace").join("config.toml")
}

pub fn default_socket_path() -> PathBuf {
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/devspace-{}.sock", uid))
}

fn dirs_path(kind: &str) -> PathBuf {
    match kind {
        "config" => {
            if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
                PathBuf::from(xdg)
            } else if let Ok(home) = std::env::var("HOME") {
                PathBuf::from(home).join(".config")
            } else {
                PathBuf::from("/tmp")
            }
        }
        _ => PathBuf::from("/tmp"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_global_config() {
        let config = GlobalConfig::default();
        assert_eq!(config.proxy.http_port, 8080);
        assert_eq!(config.proxy.bind_address, "127.0.0.1");
        assert_eq!(config.daemon.log_level, "info");
        assert_eq!(config.editor.preferred, "auto");
        assert_eq!(config.editor.port_range, (4000, 4099));
    }

    #[test]
    fn test_parse_global_config() {
        let toml_str = r#"
[proxy]
http_port = 9090
bind_address = "127.0.0.1"

[daemon]
log_level = "debug"

[editor]
preferred = "cursor"
port_range = [5000, 5099]
"#;
        let config: GlobalConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.proxy.http_port, 9090);
        assert_eq!(config.daemon.log_level, "debug");
        assert_eq!(config.editor.preferred, "cursor");
        assert_eq!(config.editor.port_range, (5000, 5099));
    }

    #[test]
    fn test_parse_project_config() {
        let toml_str = r#"
[project]
name = "my-app"
hostname = "my-app"

[dev]
command = "npm run dev"
port = 3000

[editor]
type = "cursor"
"#;
        let config: ProjectConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.project.name, "my-app");
        assert_eq!(config.project.hostname, Some("my-app".to_string()));
        assert_eq!(config.dev.command, Some("npm run dev".to_string()));
        assert_eq!(config.dev.port, Some(3000));
        assert_eq!(config.editor.r#type, "cursor");
    }

    #[test]
    fn test_parse_minimal_project_config() {
        let toml_str = r#"
[project]
name = "minimal"
"#;
        let config: ProjectConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.project.name, "minimal");
        assert_eq!(config.project.hostname, None);
        assert_eq!(config.dev.command, None);
    }
}
