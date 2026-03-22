use crate::error::LocalPortError;
use crate::validation;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Global daemon configuration (~/.config/localport/config.toml)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlobalConfig {
    #[serde(default = "default_tld")]
    pub tld: String,
    #[serde(default)]
    pub caddy: CaddyConfig,
    #[serde(default)]
    pub daemon: DaemonConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaddyConfig {
    #[serde(default = "default_http_port")]
    pub http_port: u16,
    #[serde(default = "default_https_port")]
    pub https_port: u16,
    #[serde(default = "default_caddy_bin")]
    pub bin: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonConfig {
    #[serde(default = "default_log_level")]
    pub log_level: String,
    #[serde(default)]
    pub socket_path: Option<String>,
    #[serde(default = "default_dns_port")]
    pub dns_port: u16,
}

fn default_tld() -> String {
    "test".to_string()
}

fn default_http_port() -> u16 {
    8080
}

fn default_https_port() -> u16 {
    8443
}

fn default_caddy_bin() -> String {
    "caddy".to_string()
}

fn default_log_level() -> String {
    "info".to_string()
}

fn default_dns_port() -> u16 {
    5553
}

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            tld: default_tld(),
            caddy: CaddyConfig::default(),
            daemon: DaemonConfig::default(),
        }
    }
}

impl Default for CaddyConfig {
    fn default() -> Self {
        Self {
            http_port: default_http_port(),
            https_port: default_https_port(),
            bin: default_caddy_bin(),
        }
    }
}

impl Default for DaemonConfig {
    fn default() -> Self {
        Self {
            log_level: default_log_level(),
            socket_path: None,
            dns_port: default_dns_port(),
        }
    }
}

impl GlobalConfig {
    /// Returns the path to the bundled caddy binary: ~/.config/localport/bin/caddy
    pub fn caddy_bin_path() -> PathBuf {
        Self::config_dir().join("bin").join("caddy")
    }

    /// Resolve the caddy binary path: use bundled copy if it exists,
    /// otherwise fall back to the configured bin (which may be on PATH).
    pub fn resolve_caddy_bin(&self) -> String {
        let bundled = Self::caddy_bin_path();
        if bundled.exists() {
            return bundled.to_string_lossy().to_string();
        }
        self.caddy.bin.clone()
    }

    pub fn validate(&self) -> Result<(), LocalPortError> {
        if !validation::is_valid_tld(&self.tld) {
            return Err(LocalPortError::Config(format!(
                "invalid tld '{}': must contain only lowercase alphanumerics and hyphens",
                self.tld
            )));
        }
        Ok(())
    }

    pub fn load() -> Result<Self, LocalPortError> {
        let path = global_config_path();
        let config = if path.exists() {
            let content = std::fs::read_to_string(&path).map_err(LocalPortError::Io)?;
            toml::from_str(&content).map_err(|e| {
                LocalPortError::Config(format!("failed to parse {}: {}", path.display(), e))
            })?
        } else {
            Self::default()
        };
        config.validate()?;
        Ok(config)
    }

    pub fn socket_path(&self) -> PathBuf {
        if let Some(ref p) = self.daemon.socket_path {
            PathBuf::from(p)
        } else {
            default_socket_path()
        }
    }

    pub fn config_dir() -> PathBuf {
        dirs_path("config").join("localport")
    }

    pub fn caddyfile_path(&self) -> PathBuf {
        Self::config_dir().join("Caddyfile")
    }
}

pub fn global_config_path() -> PathBuf {
    dirs_path("config").join("localport").join("config.toml")
}

pub fn default_socket_path() -> PathBuf {
    // SAFETY: getuid() is always safe — no preconditions, no side effects.
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/localport-{}.sock", uid))
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
        assert_eq!(config.tld, "test");
        assert_eq!(config.caddy.http_port, 8080);
        assert_eq!(config.caddy.https_port, 8443);
        assert_eq!(config.caddy.bin, "caddy");
        assert_eq!(config.daemon.log_level, "info");
        assert_eq!(config.daemon.dns_port, 5553);
    }

    #[test]
    fn test_parse_global_config() {
        let toml_str = r#"
tld = "localhost"

[caddy]
http_port = 9090
https_port = 9443
bin = "/usr/local/bin/caddy"

[daemon]
log_level = "debug"
dns_port = 6000
"#;
        let config: GlobalConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.tld, "localhost");
        assert_eq!(config.caddy.http_port, 9090);
        assert_eq!(config.caddy.https_port, 9443);
        assert_eq!(config.daemon.log_level, "debug");
        assert_eq!(config.daemon.dns_port, 6000);
    }

    #[test]
    fn test_backward_compat_minimal_config() {
        let toml_str = r#"
[daemon]
log_level = "debug"
"#;
        let config: GlobalConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.tld, "test");
        assert_eq!(config.caddy.http_port, 8080);
        assert_eq!(config.daemon.dns_port, 5553);
    }

}
