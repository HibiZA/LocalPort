/// The TLD used when no custom DNS is needed — browsers resolve *.localhost natively.
pub const LOCALHOST_TLD: &str = "localhost";

/// Validate that a string is a valid DNS label (single component).
/// Allows lowercase alphanumerics and hyphens, 1-63 chars, no leading/trailing hyphens.
pub fn is_valid_dns_label(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        && !s.starts_with('-')
        && !s.ends_with('-')
}

/// Validate that a hostname is safe to use in a Caddyfile and as a DNS name.
/// Must be one or more valid DNS labels separated by dots.
pub fn is_valid_hostname(s: &str) -> bool {
    !s.is_empty() && s.split('.').all(is_valid_dns_label)
}

/// Validate that a TLD is safe to use in file paths and DNS config.
pub fn is_valid_tld(s: &str) -> bool {
    is_valid_dns_label(s)
}

/// Normalize a raw project name into a DNS-friendly form: lowercase, with
/// underscores replaced by hyphens (so `grid_businessCalc` becomes
/// `grid-businesscalc`). Does NOT guarantee validity — callers should still
/// check the result with [`is_valid_dns_label`].
///
/// Shared by daemon registration, the port watcher's tag attribution, and the
/// `localport run` wrapper so all three agree on the hostname a project maps to.
pub fn normalize_project_name(raw: &str) -> String {
    raw.to_lowercase().replace('_', "-")
}

/// Turn a user-supplied hostname override into a fully-qualified hostname.
///
/// A bare label (`"my-app"`) gets `.<tld>` appended; a dotted name
/// (`"my-app.test"`) is kept as-is. Input is lowercased and a trailing dot is
/// dropped. Returns `None` if the result is not a valid hostname.
pub fn qualify_hostname(raw: &str, tld: &str) -> Option<String> {
    let h = raw.trim().trim_end_matches('.').to_lowercase();
    let h = if h.contains('.') {
        h
    } else {
        format!("{h}.{tld}")
    };
    is_valid_hostname(&h).then_some(h)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_dns_labels() {
        assert!(is_valid_dns_label("test"));
        assert!(is_valid_dns_label("my-app"));
        assert!(is_valid_dns_label("app123"));
        assert!(is_valid_dns_label("a"));
    }

    #[test]
    fn test_invalid_dns_labels() {
        assert!(!is_valid_dns_label(""));
        assert!(!is_valid_dns_label("-start"));
        assert!(!is_valid_dns_label("end-"));
        assert!(!is_valid_dns_label("has space"));
        assert!(!is_valid_dns_label("has.dot"));
        assert!(!is_valid_dns_label("UPPER"));
        assert!(!is_valid_dns_label("has\"quote"));
        assert!(!is_valid_dns_label("has\nnewline"));
        assert!(!is_valid_dns_label(&"a".repeat(64)));
    }

    #[test]
    fn test_valid_hostnames() {
        assert!(is_valid_hostname("myapp.test"));
        assert!(is_valid_hostname("my-app.test"));
        assert!(is_valid_hostname("sub.domain.test"));
        assert!(is_valid_hostname("localhost"));
    }

    #[test]
    fn test_invalid_hostnames() {
        assert!(!is_valid_hostname(""));
        assert!(!is_valid_hostname(".test"));
        assert!(!is_valid_hostname("test."));
        assert!(!is_valid_hostname("has space.test"));
        assert!(!is_valid_hostname("injection\nattack.test"));
        assert!(!is_valid_hostname("../../../evil"));
    }

    #[test]
    fn test_valid_tlds() {
        assert!(is_valid_tld("test"));
        assert!(is_valid_tld("localhost"));
        assert!(is_valid_tld("dev"));
    }

    #[test]
    fn test_invalid_tlds() {
        assert!(!is_valid_tld(""));
        assert!(!is_valid_tld("../evil"));
        assert!(!is_valid_tld("has.dot"));
        assert!(!is_valid_tld("has space"));
    }

    #[test]
    fn test_normalize_project_name() {
        assert_eq!(normalize_project_name("my-app"), "my-app");
        assert_eq!(normalize_project_name("My_App"), "my-app");
        assert_eq!(
            normalize_project_name("grid_businessProductCalc"),
            "grid-businessproductcalc"
        );
        // Output is normalized but not guaranteed valid; callers validate.
        assert!(is_valid_dns_label(&normalize_project_name("My_App")));
        assert!(!is_valid_dns_label(&normalize_project_name("has space")));
    }

    #[test]
    fn test_qualify_hostname() {
        assert_eq!(
            qualify_hostname("my-app", "test"),
            Some("my-app.test".into())
        );
        assert_eq!(
            qualify_hostname("My-App.test.", "test"),
            Some("my-app.test".into())
        );
        assert_eq!(
            qualify_hostname("api.web.test", "test"),
            Some("api.web.test".into())
        );
        assert_eq!(qualify_hostname("", "test"), None);
        assert_eq!(qualify_hostname("has space", "test"), None);
    }
}
