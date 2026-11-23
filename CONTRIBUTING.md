# Contributing to Sonea

Thank you for your interest in contributing to **Sonea**! Bug fixes, performance improvements, localization refinements, and thoughtful features that fit Sonea's minimalist, offline-first philosophy are always welcome.

## Development Setup

### Prerequisites
- **Flutter SDK** (`>= 3.29`) & Dart SDK (`^3.14.0`)
- **Rust toolchain** (`stable`) with Android target:
  ```bash
  rustup target add aarch64-linux-android
  ```
- **Android SDK** (`compileSdk 36`, `minSdk 26`) & **NDK** (`28.2.13676358`)
- **`flutter_rust_bridge_codegen` `2.11.1`** *(only required when modifying Rust `pub fn` FFI signatures)*:
  ```bash
  cargo install flutter_rust_bridge_codegen --version 2.11.1
  ```

### Getting Started
```bash
git clone https://github.com/BoynuzluKitsune/Sonea.git
cd Sonea
flutter pub get
```

If you edit any `pub fn` or exported struct in `rust/src/api/`, regenerate the FFI bindings before testing:
```bash
flutter_rust_bridge_codegen generate
```

## Architecture & Coding Conventions
- **UI Framework:** Use `package:material_ui/material_ui.dart` and Riverpod (`flutter_riverpod`). Avoid importing `package:flutter/material.dart` directly.
- **Localization:** Zero hardcoded UI strings — add every user-facing label, badge, and dialog message to `lib/l10n/app_strings.dart` in both **Turkish (`tr`)** and **English (`en`)**.
- **Rust FFI Safety:** Never expose `rusqlite::Row` or pooled SQLite connections in `pub fn` signatures scanned by `flutter_rust_bridge`. Keep all outbound network requests HTTPS-only (`rustls-tls`) with bounded response reads.
- **Privacy & Security:** Sonea is strictly ad-free and telemetry-free. Never commit signing keystores (`*.jks`, `*.keystore`) or `android/key.properties`.

## Verification Checklist

Run all checks locally before opening a pull request — CI enforces the same gates:

```bash
# Rust strict Clippy lints & unit tests
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml

# Flutter static analysis & test suite
flutter analyze
flutter test
```

## Pull Request Guidelines
1. Keep PRs focused on a single bug fix or cohesive feature.
2. Use clear, descriptive commit messages (e.g., `fix: ...`, `feat: ...`, `docs: ...`).
3. Include unit or widget tests covering new logic or bug regressions.
4. For UI changes, attach before/after screenshots (ideally tested on a `360dp` width viewport in both Dark and Light modes).
5. Ensure all checks in the verification checklist pass with zero warnings.
