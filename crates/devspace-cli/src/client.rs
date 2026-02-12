use devspace_proto::messages::{Request, Response};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

static REQUEST_ID: AtomicU64 = AtomicU64::new(1);

pub struct IpcClient {
    stream: BufReader<UnixStream>,
}

impl IpcClient {
    pub async fn connect(socket_path: &Path) -> anyhow::Result<Self> {
        let stream = UnixStream::connect(socket_path).await.map_err(|e| {
            if e.kind() == std::io::ErrorKind::ConnectionRefused
                || e.kind() == std::io::ErrorKind::NotFound
            {
                anyhow::anyhow!("daemon not running (could not connect to {})", socket_path.display())
            } else {
                anyhow::anyhow!("failed to connect to daemon: {}", e)
            }
        })?;

        Ok(Self {
            stream: BufReader::new(stream),
        })
    }

    pub async fn call(
        &mut self,
        method: &str,
        params: serde_json::Value,
    ) -> anyhow::Result<Response> {
        let id = REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let request = Request::new(method, params, id);

        let mut json = serde_json::to_string(&request)?;
        json.push('\n');

        self.stream
            .get_mut()
            .write_all(json.as_bytes())
            .await?;

        let mut line = String::new();
        self.stream.read_line(&mut line).await?;

        if line.is_empty() {
            anyhow::bail!("daemon closed connection");
        }

        let response: Response = serde_json::from_str(&line)?;
        Ok(response)
    }
}
