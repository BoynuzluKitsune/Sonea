#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    #[cfg(target_os = "android")]
    {
        let level_spec = if cfg!(debug_assertions) {
            "error,rust_lib_sonea=info"
        } else {
            "error"
        };
        let max_level = if cfg!(debug_assertions) {
            log::LevelFilter::Info
        } else {
            log::LevelFilter::Error
        };
        let filter = android_logger::FilterBuilder::new()
            .parse(level_spec)
            .build();
        let _ = android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(max_level)
                .with_filter(filter),
        );
    }
    flutter_rust_bridge::setup_default_user_utils();
}
