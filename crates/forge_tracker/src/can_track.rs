/// Version information
pub const VERSION: &str = match option_env!("APP_VERSION") {
    None => env!("CARGO_PKG_VERSION"),
    Some(v) => v,
};

/// Checks if tracking is enabled: release build and no `FORGE_TRACKER=false`
/// opt-out. Gates both PostHog events and the PostHog tracing writer.
pub fn can_track() -> bool {
    can_track_inner(Some(VERSION)) && crate::dispatch::tracking_enabled()
}

fn can_track_inner<V: AsRef<str>>(version: Option<V>) -> bool {
    if let Some(v) = version {
        let v_str = v.as_ref();
        !(v_str.contains("dev") || v_str.contains("0.1.0"))
    } else {
        true // If no version provided, assume prod
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_enabled_none_is_prod_true() {
        assert!(can_track_inner(Some("1.0.0")));
    }

    #[test]
    fn usage_enabled_none_is_prod_false() {
        assert!(!can_track_inner(Some("0.1.0-dev")));
        assert!(!can_track_inner(Some("1.0.0-dev")));
        assert!(!can_track_inner(Some("0.1.0")));
    }
}
