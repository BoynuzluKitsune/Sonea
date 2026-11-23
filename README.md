<div align="center">

<img src="assets/icon/logo.svg" alt="Sonea" width="88" />

# Sonea

An offline-first Android music player built with Flutter and Rust.

[![Release](https://img.shields.io/github/v/release/BoynuzluKitsune/Sonea?style=flat-square&label=Release&color=78C7C7)](https://github.com/BoynuzluKitsune/Sonea/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-555555?style=flat-square)](LICENSE)
[![Android ARM64](https://img.shields.io/badge/Android-ARM64-3DDC84?style=flat-square&logo=android&logoColor=0B0C0E)](https://github.com/BoynuzluKitsune/Sonea/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/BoynuzluKitsune/Sonea/ci.yml?style=flat-square&label=CI)](https://github.com/BoynuzluKitsune/Sonea/actions/workflows/ci.yml)

<br />

**[Download latest APK](https://github.com/BoynuzluKitsune/Sonea/releases/latest)** · [Features](#features) · [Themes](#themes) · [Build](#build-from-source) · [Türkçe](#turkce)

</div>

<br />

<div align="center">
<table>
  <tr>
    <td align="center"><img src="docs/screenshots/library.png" width="210" alt="Library" /></td>
    <td align="center"><img src="docs/screenshots/now_playing.png" width="210" alt="Now Playing" /></td>
    <td align="center"><img src="docs/screenshots/lyrics.png" width="210" alt="Synced Lyrics" /></td>
    <td align="center"><img src="docs/screenshots/themes.png" width="210" alt="Themes" /></td>
  </tr>
  <tr>
    <td align="center"><sub>Library</sub></td>
    <td align="center"><sub>Now Playing</sub></td>
    <td align="center"><sub>Synced Lyrics</sub></td>
    <td align="center"><sub>Themes</sub></td>
  </tr>
</table>
</div>

## Features

- Local library with folder browsing, short-audio filtering, `# A–Z` fast scroller, and 2×2 playlist covers
- Gapless playback, 5-band equalizer, ReplayGain (`Track` / `Album`), and sleep timer
- Time-synced karaoke lyrics (local `.lrc`/embedded tags, parallel multi-source lookup, instrumental detection, manual search/paste) and offline Rust transliteration for Japanese, Korean, and Cyrillic
- 10 dual-mode (Light/Dark) themes based on Sanzo Wada's *A Dictionary of Color Combinations*
- 5 theme-synced Android home screen widgets (`Cover Tile`, `Micro Pill`, `Quick Mix Dock`, `Studio Card`, `Up Next Desk`)
- No ads, no telemetry, HTTPS-only network calls

## Themes

All 10 palettes include both Light and Dark modes (`System | Light | Dark`).

| Plate | Name | Font | Colors |
| :---: | :--- | :--- | :--- |
| `No. 255` | Kuro & Asagi | Plus Jakarta Sans | ![#0B0C0E](https://img.shields.io/badge/-%230B0C0E-0B0C0E?style=flat-square) ![#78C7C7](https://img.shields.io/badge/-%2378C7C7-78C7C7?style=flat-square) ![#C2B038](https://img.shields.io/badge/-%23C2B038-C2B038?style=flat-square) ![#B85A14](https://img.shields.io/badge/-%23B85A14-B85A14?style=flat-square) |
| `No. 340` | Taisho Avant-Garde | Space Grotesk + Inter | ![#0B0C0E](https://img.shields.io/badge/-%230B0C0E-0B0C0E?style=flat-square) ![#1EA67E](https://img.shields.io/badge/-%231EA67E-1EA67E?style=flat-square) ![#E8451E](https://img.shields.io/badge/-%23E8451E-E8451E?style=flat-square) ![#B0B8B6](https://img.shields.io/badge/-%23B0B8B6-B0B8B6?style=flat-square) |
| `No. 303` | Showa Studio | IBM Plex Sans | ![#171C16](https://img.shields.io/badge/-%23171C16-171C16?style=flat-square) ![#E8451E](https://img.shields.io/badge/-%23E8451E-E8451E?style=flat-square) ![#EEE098](https://img.shields.io/badge/-%23EEE098-EEE098?style=flat-square) ![#B0B8B6](https://img.shields.io/badge/-%23B0B8B6-B0B8B6?style=flat-square) |
| `No. 288` | Kenpou Vinyl | Newsreader + Inter | ![#0B0C0E](https://img.shields.io/badge/-%230B0C0E-0B0C0E?style=flat-square) ![#F59614](https://img.shields.io/badge/-%23F59614-F59614?style=flat-square) ![#5E2F42](https://img.shields.io/badge/-%235E2F42-5E2F42?style=flat-square) ![#4A3316](https://img.shields.io/badge/-%234A3316-4A3316?style=flat-square) |
| `No. 331` | Kachi Indigo | Outfit | ![#10102A](https://img.shields.io/badge/-%2310102A-10102A?style=flat-square) ![#C9265B](https://img.shields.io/badge/-%23C9265B-C9265B?style=flat-square) ![#8E5EB8](https://img.shields.io/badge/-%238E5EB8-8E5EB8?style=flat-square) ![#3B248C](https://img.shields.io/badge/-%233B248C-3B248C?style=flat-square) |
| `No. 271` | Tetsu Jade | DM Sans | ![#101E1B](https://img.shields.io/badge/-%23101E1B-101E1B?style=flat-square) ![#8CC7A1](https://img.shields.io/badge/-%238CC7A1-8CC7A1?style=flat-square) ![#1E7E84](https://img.shields.io/badge/-%231E7E84-1E7E84?style=flat-square) ![#B81D4E](https://img.shields.io/badge/-%23B81D4E-B81D4E?style=flat-square) |
| `No. 329` | Kakitsubata Dusk | Fraunces + Inter | ![#1A2226](https://img.shields.io/badge/-%231A2226-1A2226?style=flat-square) ![#F2B84B](https://img.shields.io/badge/-%23F2B84B-F2B84B?style=flat-square) ![#B5A3B8](https://img.shields.io/badge/-%23B5A3B8-B5A3B8?style=flat-square) ![#3D1236](https://img.shields.io/badge/-%233D1236-3D1236?style=flat-square) |
| `No. 263` | Kuriume Ceramic | Manrope | ![#1A2226](https://img.shields.io/badge/-%231A2226-1A2226?style=flat-square) ![#E0A672](https://img.shields.io/badge/-%23E0A672-E0A672?style=flat-square) ![#B0DAC8](https://img.shields.io/badge/-%23B0DAC8-B0DAC8?style=flat-square) ![#A63A14](https://img.shields.io/badge/-%23A63A14-A63A14?style=flat-square) |
| `No. 348` | Haishoku Finale | Playfair Display + Inter | ![#171C16](https://img.shields.io/badge/-%23171C16-171C16?style=flat-square) ![#C4C18E](https://img.shields.io/badge/-%23C4C18E-C4C18E?style=flat-square) ![#2E5929](https://img.shields.io/badge/-%232E5929-2E5929?style=flat-square) ![#3D1236](https://img.shields.io/badge/-%233D1236-3D1236?style=flat-square) |
| `No. 343` | Shiracha Editorial | Lora + IBM Plex Sans | ![#EFE8D4](https://img.shields.io/badge/-%23EFE8D4-EFE8D4?style=flat-square) ![#133F66](https://img.shields.io/badge/-%23133F66-133F66?style=flat-square) ![#A63A14](https://img.shields.io/badge/-%23A63A14-A63A14?style=flat-square) ![#524E2E](https://img.shields.io/badge/-%23524E2E-524E2E?style=flat-square) |

## Architecture

```text
Flutter UI (Riverpod, material_ui)
  ├── flutter_rust_bridge 2.11.1 ──▶ Rust core (SQLite WAL, lofty indexer, parallel lyrics, lindera)
  └── Android platform           ──▶ just_audio / ExoPlayer, MediaSession, 5 AppWidgets
```

<a id="build-from-source"></a>
<details>
<summary><strong>Build from source</strong></summary>

Requirements: Flutter SDK (`>= 3.29`), Rust (`stable` + `aarch64-linux-android`), Android SDK (`compileSdk 36`, `minSdk 26`), NDK `28.2.13676358`.

```bash
flutter pub get
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

If you change exported Rust FFI signatures, regenerate bindings with `flutter_rust_bridge_codegen generate` (`2.11.1`).

For signed release builds, add a gitignored `android/key.properties` file (`storePassword`, `keyPassword`, `keyAlias`, `storeFile`). If absent, Gradle falls back to debug signing.

</details>

<a id="turkce"></a>
<details>
<summary><strong>Türkçe özet</strong></summary>

**Sonea**, Flutter ve Rust ile geliştirilmiş, çevrimdışı odaklı bir Android müzik çalardır.

- Klasör tarayıcılı yerel kütüphane, kısa ses filtresi, `# A–Z` hızlı kaydırıcı ve 2×2 kolajlı çalma listeleri
- Boşluksuz (gapless) oynatma, 5 bant ekolayzır, ReplayGain (`Şarkı` / `Albüm`) ve uyku zamanlayıcısı
- Zaman senkronize karaoke şarkı sözleri (yerel `.lrc`/gömülü etiketler, paralel çok kaynaklı arama, enstrümantal parça algılama, elle arama/yapıştırma) ve çevrimdışı Rust Japonca/Korece/Kiril transliterasyonu
- Sanzo Wada'nın *A Dictionary of Color Combinations* (1933–34) eserinden uyarlanmış 10 çift modlu (Aydınlık/Karanlık) tema
- Aktif temayla uyumlu 5 Android ana ekran widget'ı (`Cover Tile`, `Micro Pill`, `Quick Mix Dock`, `Studio Card`, `Up Next Desk`)
- Reklamsız, takipçisiz, yalnızca HTTPS ağ çağrıları

</details>

## License

Licensed under [GPL-3.0](LICENSE). Third-party licenses are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

Color palettes adapted from Sanzo Wada's *Haishoku Soukan* (1933–34). Built with Flutter, Rust, `flutter_rust_bridge`, `just_audio`, `lofty`, `rusqlite`, `lindera`, and `wana_kana`.
