use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub name: String,
    pub hostname: String,
    pub directory: PathBuf,
    pub config: ProjectConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Route {
    pub hostname: String,
    pub upstream_port: u16,
    pub route_type: RouteType,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum RouteType {
    DevServer,
    Editor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProcessStatus {
    Starting,
    Running,
    Stopped,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessInfo {
    pub pid: u32,
    pub project_id: String,
    pub process_type: ProcessType,
    pub command: String,
    pub port: Option<u16>,
    pub status: ProcessStatus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProcessType {
    DevServer,
    Editor,
    Agent,
    Custom,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditorInfo {
    pub binary: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectConfig {
    pub project: ProjectSection,
    #[serde(default)]
    pub dev: DevSection,
    #[serde(default)]
    pub editor: EditorSection,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectSection {
    pub name: String,
    #[serde(default)]
    pub hostname: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct DevSection {
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub directory: Option<String>,
    #[serde(default)]
    pub env: std::collections::HashMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct EditorSection {
    #[serde(default = "default_editor_type")]
    pub r#type: String,
}

fn default_editor_type() -> String {
    "auto".to_string()
}
