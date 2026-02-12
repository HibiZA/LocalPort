use devspace_core::types::{ProcessInfo, ProcessStatus, ProcessType};
use std::collections::HashMap;
use std::path::Path;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

struct ManagedProcess {
    child: Child,
    info: ProcessInfo,
}

pub struct ProcessManager {
    processes: HashMap<String, ManagedProcess>,
}

impl ProcessManager {
    pub fn new() -> Self {
        Self {
            processes: HashMap::new(),
        }
    }

    /// Spawn a new managed process.
    pub async fn spawn(
        &mut self,
        id: String,
        command: &str,
        cwd: &Path,
        env: &HashMap<String, String>,
        process_type: ProcessType,
    ) -> anyhow::Result<u32> {
        // Parse command into program + args (simple shell-like splitting)
        let parts: Vec<&str> = command.split_whitespace().collect();
        if parts.is_empty() {
            anyhow::bail!("empty command");
        }

        let mut cmd = Command::new(parts[0]);
        if parts.len() > 1 {
            cmd.args(&parts[1..]);
        }
        cmd.current_dir(cwd);
        cmd.envs(env);
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());

        // Don't let the child become a zombie — put it in its own process group
        unsafe {
            cmd.pre_exec(|| {
                libc::setpgid(0, 0);
                Ok(())
            });
        }

        let mut child = cmd.spawn()?;
        let pid = child.id().unwrap_or(0);

        // Spawn stdout/stderr reader tasks
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();

        let info = ProcessInfo {
            pid,
            project_id: id.clone(),
            process_type,
            command: command.to_string(),
            port: None,
            status: ProcessStatus::Running,
        };

        let managed = ManagedProcess { child, info };

        self.processes.insert(id.clone(), managed);

        // Spawn output readers in background
        if let Some(stdout) = stdout {
            let id_clone = id.clone();
            tokio::spawn(async move {
                let reader = BufReader::new(stdout);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    tracing::debug!("[{}] stdout: {}", id_clone, line);
                }
            });
        }

        if let Some(stderr) = stderr {
            let id_clone = id.clone();
            tokio::spawn(async move {
                let reader = BufReader::new(stderr);
                let mut lines = reader.lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    tracing::debug!("[{}] stderr: {}", id_clone, line);
                }
            });
        }

        tracing::info!("spawned process '{}' (pid {}): {}", id, pid, command);
        Ok(pid)
    }

    /// Stop a managed process (SIGTERM, then SIGKILL after timeout).
    pub async fn stop(&mut self, id: &str) -> anyhow::Result<()> {
        let managed = self
            .processes
            .get_mut(id)
            .ok_or_else(|| anyhow::anyhow!("process '{}' not found", id))?;

        let pid = managed.info.pid;
        tracing::info!("stopping process '{}' (pid {})", id, pid);

        // Send SIGTERM to the process group
        unsafe {
            libc::kill(-(pid as i32), libc::SIGTERM);
        }

        // Wait up to 5 seconds for graceful shutdown
        let result = tokio::time::timeout(
            tokio::time::Duration::from_secs(5),
            managed.child.wait(),
        )
        .await;

        match result {
            Ok(Ok(status)) => {
                tracing::info!("process '{}' exited with {}", id, status);
            }
            Ok(Err(e)) => {
                tracing::warn!("error waiting for '{}': {}", id, e);
            }
            Err(_) => {
                // Timeout — send SIGKILL
                tracing::warn!("process '{}' didn't exit, sending SIGKILL", id);
                unsafe {
                    libc::kill(-(pid as i32), libc::SIGKILL);
                }
                let _ = managed.child.wait().await;
            }
        }

        self.processes.remove(id);
        Ok(())
    }

    /// Stop all managed processes.
    pub async fn stop_all(&mut self) {
        let ids: Vec<String> = self.processes.keys().cloned().collect();
        for id in ids {
            if let Err(e) = self.stop(&id).await {
                tracing::warn!("error stopping '{}': {}", id, e);
            }
        }
    }

    pub fn list(&self) -> Vec<&ProcessInfo> {
        self.processes.values().map(|m| &m.info).collect()
    }

    pub fn get(&self, id: &str) -> Option<&ProcessInfo> {
        self.processes.get(id).map(|m| &m.info)
    }

    /// Check and update status of all processes (reap zombies).
    pub async fn reap(&mut self) {
        for managed in self.processes.values_mut() {
            if let Ok(Some(status)) = managed.child.try_wait() {
                if status.success() {
                    managed.info.status = ProcessStatus::Stopped;
                } else {
                    managed.info.status = ProcessStatus::Failed;
                }
            }
        }
    }
}
