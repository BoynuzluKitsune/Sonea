# Contributing

Contributions, bug reports, and pull requests are welcome.

## Local Setup

Requirements:
- Flutter SDK (`>= 3.29`)
- Rust (`stable`) with `rustup target add aarch64-linux-android`
- Android SDK (`compileSdk 36`, `minSdk 26`) and NDK `28.2.13676358`
- `flutter_rust_bridge_codegen` `2.11.1` (only when changing exported Rust `pub fn` signatures)

```bash
git clone https://github.com/BoynuzluKitsune/Sonea.git
cd Sonea
flutter pub get
```

If you change Rust FFI signatures under `rust/src/api/`, regenerate bindings:

```bash
flutter_rust_bridge_codegen generate
```

## Conventions

- Import `package:material_ui/material_ui.dart` in Flutter UI code (do not import `package:flutter/material.dart`).
- Put all user-facing strings in `lib/l10n/app_strings.dart` for both Turkish (`tr`) and English (`en`).
- Never expose `rusqlite::Row` or pooled SQLite connections in FRB-scanned `pub fn` signatures.
- Keep outbound network calls HTTPS-only (`rustls-tls`) and never commit signing keys or `android/key.properties`.

## Checks Before Opening a PR

```bash
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml
flutter analyze
flutter test
```

Keep PRs small and focused, add tests for bug fixes or new behavior, and include screenshots for UI changes.
