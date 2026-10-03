use thiserror::Error;

#[derive(Debug, Error)]
pub enum LocalPortError {
    #[error("config error: {0}")]
    Config(String),

    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}
