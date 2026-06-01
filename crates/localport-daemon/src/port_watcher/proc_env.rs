//! Read a target process's environment variables.
//!
//! This is the **portable seam** for ground-truth project attribution. The
//! `localport run` wrapper sets `LOCALPORT_PROJECT` in a dev server's
//! environment; that tag is inherited by every child the server spawns. When
//! the watcher discovers a new listening PID it reads the tag back from here
//! and attributes the port to that project directly — no cwd guessing.
//!
//! The OS-specific syscall lives entirely in this module. The attribution
//! logic in `mod.rs` only ever calls [`get_pid_env_var`] and never touches a
//! syscall, so a Linux implementation (parse `/proc/<pid>/environ`) can drop
//! in behind the same function signature without changing any caller.
//!
//! - **macOS:** `sysctl(KERN_PROCARGS2)` — same mechanism `ps eww <pid>` uses;
//!   works for processes owned by the same uid as the daemon (which is the
//!   case for dev servers the user launches).
//! - **Other:** stub returning `None` until a real implementation lands.

/// Look up a single environment variable of process `pid`.
///
/// Returns `None` if the variable is unset or the environment is unreadable
/// (process exited, owned by a different user, permission denied, …).
pub fn get_pid_env_var(pid: u32, key: &str) -> Option<String> {
    imp::get_pid_env_var(pid, key)
}

#[cfg(target_os = "macos")]
mod imp {
    use libc::{c_int, c_void, size_t, sysctl, CTL_KERN, KERN_ARGMAX, KERN_PROCARGS2};

    pub fn get_pid_env_var(pid: u32, key: &str) -> Option<String> {
        let buf = read_procargs2(pid)?;
        find_env_var(&buf, key)
    }

    /// Fetch the raw `KERN_PROCARGS2` blob for `pid`.
    fn read_procargs2(pid: u32) -> Option<Vec<u8>> {
        // 1. Ask the kernel for the maximum args size to allocate a buffer
        //    large enough to hold any process's args + environment.
        let mut argmax: c_int = 0;
        let mut size = std::mem::size_of::<c_int>() as size_t;
        let mut mib = [CTL_KERN, KERN_ARGMAX];
        let rc = unsafe {
            sysctl(
                mib.as_mut_ptr(),
                mib.len() as u32,
                &mut argmax as *mut _ as *mut c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 || argmax <= 0 {
            return None;
        }

        // 2. Fetch the target process's argv + envp into the buffer. The
        //    kernel rejects the call (EINVAL) for pids owned by another user,
        //    which is exactly the safety boundary we want.
        let mut buf = vec![0u8; argmax as usize];
        let mut size = buf.len() as size_t;
        let mut mib = [CTL_KERN, KERN_PROCARGS2, pid as c_int];
        let rc = unsafe {
            sysctl(
                mib.as_mut_ptr(),
                mib.len() as u32,
                buf.as_mut_ptr() as *mut c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if rc != 0 {
            return None;
        }
        buf.truncate(size as usize);
        Some(buf)
    }

    /// Parse a `KERN_PROCARGS2` blob and return the value of `key` from the
    /// environment section (not the argv section).
    ///
    /// Blob layout (see Darwin `kern_sysctl.c`):
    /// ```text
    ///   int    argc
    ///   char   exec_path[]        NUL-terminated, then alignment padding NULs
    ///   char   argv[0..argc]      each NUL-terminated
    ///   char   envp[..]           each NUL-terminated, until end of blob
    /// ```
    fn find_env_var(buf: &[u8], key: &str) -> Option<String> {
        let int_size = std::mem::size_of::<c_int>();
        if buf.len() < int_size {
            return None;
        }
        let argc = c_int::from_ne_bytes(buf[..int_size].try_into().ok()?);
        if argc < 0 {
            return None;
        }
        let mut pos = int_size;

        // Skip the exec_path string ...
        while pos < buf.len() && buf[pos] != 0 {
            pos += 1;
        }
        // ... and the alignment NULs that follow it, landing on argv[0].
        while pos < buf.len() && buf[pos] == 0 {
            pos += 1;
        }

        // Step over `argc` NUL-terminated argument strings.
        let mut skipped = 0;
        while skipped < argc && pos < buf.len() {
            while pos < buf.len() && buf[pos] != 0 {
                pos += 1;
            }
            pos += 1; // step past the terminating NUL
            skipped += 1;
        }

        // Everything remaining is `KEY=VALUE` environment entries.
        let needle = format!("{key}=");
        while pos < buf.len() {
            let start = pos;
            while pos < buf.len() && buf[pos] != 0 {
                pos += 1;
            }
            if pos > start {
                if let Ok(entry) = std::str::from_utf8(&buf[start..pos]) {
                    if let Some(value) = entry.strip_prefix(&needle) {
                        return Some(value.to_string());
                    }
                }
            }
            pos += 1; // step past the terminating NUL
        }
        None
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::process::Command;

        /// Build a synthetic `KERN_PROCARGS2` blob to exercise the parser
        /// against a known layout.
        fn make_blob(argc: i32, exec_path: &str, args: &[&str], envs: &[&str]) -> Vec<u8> {
            let mut buf = Vec::new();
            buf.extend_from_slice(&argc.to_ne_bytes());
            buf.extend_from_slice(exec_path.as_bytes());
            buf.push(0);
            buf.push(0); // alignment padding NUL
            for a in args {
                buf.extend_from_slice(a.as_bytes());
                buf.push(0);
            }
            for e in envs {
                buf.extend_from_slice(e.as_bytes());
                buf.push(0);
            }
            buf
        }

        #[test]
        fn parses_env_value() {
            let blob = make_blob(
                2,
                "/usr/bin/node",
                &["node", "server.js"],
                &["PATH=/usr/bin", "LOCALPORT_PROJECT=web", "HOME=/Users/x"],
            );
            assert_eq!(
                find_env_var(&blob, "LOCALPORT_PROJECT"),
                Some("web".to_string())
            );
        }

        #[test]
        fn missing_env_returns_none() {
            let blob = make_blob(1, "/usr/bin/node", &["node"], &["PATH=/usr/bin"]);
            assert_eq!(find_env_var(&blob, "LOCALPORT_PROJECT"), None);
        }

        #[test]
        fn argv_match_is_not_treated_as_env() {
            // A literal `LOCALPORT_PROJECT=...` appearing as an ARGUMENT must
            // not be mistaken for the environment variable.
            let blob = make_blob(
                2,
                "/usr/bin/node",
                &["node", "LOCALPORT_PROJECT=fromargv"],
                &["LOCALPORT_PROJECT=fromenv"],
            );
            assert_eq!(
                find_env_var(&blob, "LOCALPORT_PROJECT"),
                Some("fromenv".to_string())
            );
        }

        #[test]
        fn value_with_equals_is_preserved() {
            let blob = make_blob(1, "/bin/sh", &["sh"], &["X=a=b=c"]);
            assert_eq!(find_env_var(&blob, "X"), Some("a=b=c".to_string()));
        }

        /// The load-bearing test: set an env var BEFORE exec, then read it
        /// back from ANOTHER long-lived process by its PID — exactly what the
        /// watcher does to a server launched by `localport run`.
        ///
        /// Three macOS facts this guards against:
        ///   1. `KERN_PROCARGS2` returns the environment captured *at exec
        ///      time*, so the tag must be set before exec (the wrapper does).
        ///   2. The environment of SIP-protected platform binaries (e.g.
        ///      `/bin/sleep` in place) is withheld; a copy is not a platform
        ///      binary, mirroring a user-installed dev server (node/pnpm),
        ///      whose env IS readable.
        ///   3. On Apple Silicon the kernel SIGKILLs a copied Apple-signed
        ///      binary (signature/location mismatch), so we re-sign it ad-hoc
        ///      to keep it alive — otherwise the read would race a dying
        ///      process and the test would be flaky.
        #[test]
        fn reads_tag_from_a_separate_process() {
            let copy = std::env::temp_dir().join(format!("lp_proc_env_{}", std::process::id()));
            std::fs::copy("/bin/sleep", &copy).expect("copy /bin/sleep");
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&copy).unwrap().permissions();
            perms.set_mode(0o755);
            let _ = std::fs::set_permissions(&copy, perms);

            let signed = Command::new("codesign")
                .args(["-f", "-s", "-"])
                .arg(&copy)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            assert!(signed, "ad-hoc codesign of the test binary failed");

            let mut child = Command::new(&copy)
                .arg("30")
                .env("LOCALPORT_PROJECT", "spike-project")
                .spawn()
                .expect("failed to spawn child");

            let pid = child.id();

            // The child has been forked but may not have finished exec'ing yet;
            // retry briefly until its post-exec image is readable.
            let mut found = None;
            for _ in 0..40 {
                // Bail out early if the child died — that would mean we never
                // got a stable post-exec image to read (don't pass on a race).
                if let Ok(Some(_)) = child.try_wait() {
                    break;
                }
                if let Some(v) = get_pid_env_var(pid, "LOCALPORT_PROJECT") {
                    found = Some(v);
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(25));
            }

            let _ = child.kill();
            let _ = child.wait();
            let _ = std::fs::remove_file(&copy);

            assert_eq!(
                found,
                Some("spike-project".to_string()),
                "should read LOCALPORT_PROJECT from a separate, live process by pid"
            );
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    /// Linux drop-in point: parse `/proc/<pid>/environ` (NUL-separated
    /// `KEY=VALUE` entries). Stubbed until a non-macOS target is supported.
    pub fn get_pid_env_var(_pid: u32, _key: &str) -> Option<String> {
        None
    }
}
