use devspace_core::types::EditorInfo;

const EDITOR_CANDIDATES: &[(&str, &str)] = &[
    ("cursor", "Cursor"),
    ("code", "VS Code"),
    ("windsurf", "Windsurf"),
    ("code-insiders", "VS Code Insiders"),
];

/// Detect the user's preferred editor by checking PATH.
pub fn detect_editor() -> Option<EditorInfo> {
    for (binary, name) in EDITOR_CANDIDATES {
        if which::which(binary).is_ok() {
            return Some(EditorInfo {
                binary: binary.to_string(),
                name: name.to_string(),
            });
        }
    }
    None
}

/// Check if a specific editor binary supports serve-web.
pub fn supports_serve_web(binary: &str) -> bool {
    std::process::Command::new(binary)
        .args(["serve-web", "--help"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}
