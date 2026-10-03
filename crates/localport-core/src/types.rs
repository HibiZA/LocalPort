use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectConfig {
    pub project: ProjectSection,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectSection {
    /// Project name. Empty means "not set" (fall back to the directory name).
    #[serde(default)]
    pub name: String,
    /// Hostname override. A bare label (`"my-app"`) gets the configured TLD
    /// appended; a dotted name (`"my-app.test"`) is used as-is.
    #[serde(default)]
    pub hostname: Option<String>,
    /// Pin the route to this port. Without it, when a project has several
    /// listening sockets the watcher picks the most likely dev server port.
    #[serde(default)]
    pub port: Option<u16>,
}
