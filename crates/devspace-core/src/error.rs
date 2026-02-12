use thiserror::Error;

#[derive(Debug, Error)]
pub enum DevSpaceError {
    #[error("config error: {0}")]
    Config(String),

    #[error("project '{0}' not found")]
    ProjectNotFound(String),

    #[error("project '{0}' already exists")]
    ProjectAlreadyExists(String),

    #[error("daemon not running")]
    DaemonNotRunning,

    #[error("ipc error: {0}")]
    Ipc(String),

    #[error("process error: {0}")]
    Process(String),

    #[error("proxy error: {0}")]
    Proxy(String),

    #[error("port {0} is already in use")]
    PortInUse(u16),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("{0}")]
    Other(String),
}
