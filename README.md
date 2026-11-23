# Sonea

**Offline-first, 120Hz minimalist audiophile music player for Android built with Flutter and Rust.**  
**Flutter ve Rust ile geliştirilmiş, çevrimdışı odaklı, 120Hz minimalist Android müzik çalar.**

[![CI](https://img.shields.io/badge/CI-GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)](.github/workflows/ci.yml)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-2021-000000?logo=rust&logoColor=white)](https://www.rust-lang.org)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

[English](#english) · [Türkçe](#türkçe)

---

<a id="english"></a>
## English

### Overview

**Sonea** pairs a fluid 120Hz Flutter interface (`package:material_ui` + Riverpod) with a compiled native Rust core (`rust_lib_sonea` via `flutter_rust_bridge 2.11.1`) for instant local library indexing, gapless high-resolution playback, synced-first karaoke lyrics, and editorial visual craft — with **zero ads, zero analytics, zero tracking, and an offline-first architecture**.

### Key Features

- **Hybrid Flutter + Rust 120Hz Core:** Multi-threaded incremental scanner (`lofty` + bundled WAL SQLite via `rusqlite`) with live progress streaming, SHA-256 deduplicated artwork caching, memory-bounded image decoding, and Turkish/Unicode-normalized instant search across `FLAC`, `OPUS`, `MP3`, `M4A`, `AAC`, `OGG`, `WAV`, `AIFF`, and `WV`.
- **10 Dual-Mode Sanzo Wada 4-Color Themes & Bespoke Typography:** Curated from Sanzo Wada's *A Dictionary of Color Combinations* (*Haishoku Soukan*, 1933–34) — **Kuro & Asagi** (*No. 255*), **Taisho Avant-Garde** (*No. 340*), **Showa Studio** (*No. 303*), **Kenpou Vinyl** (*No. 288*), **Kachi Indigo** (*No. 331*), **Tetsu Jade** (*No. 271*), **Beni Vermilion** (*No. 217*), **Washi Moss** (*No. 276*), **Sakura Mineral** (*No. 348*), and **Kyoto Amber** (*No. 343*). Every plate ships handcrafted **Dark & Light** modes (`System | Light | Dark`), WCAG AA contrast, bespoke font pairings, dynamic corner radius, and a dedicated **Theme Gallery**.
- **6-Provider Synced-First Karaoke Lyrics Engine:**
  - Local-first (SQLite cache → sidecar `.lrc`/`.txt` → embedded audio tags) followed by a strict **synced-first** HTTPS cascade across **LRCLIB**, **KuGou**, **NetEase Cloud Music**, and **Musixmatch** before plain-text fallback (**Lyrics.ovh**, **Genius**).
  - Smart metadata cleanup (YouTube channel suffixes, track numbers, anime/OST `~` & `- TV Size` subtitles, CJK/Romaji variants), real-time smooth auto-scroll with tap-to-seek, enhanced `<mm:ss.xx>` LRC handling, offline Rust transliteration (**Japanese Kanji/Kana Romaji** via lazy-loaded `lindera` IPADIC + `wana_kana`, **Korean Hangul**, **Cyrillic**, **Greek**, **Chinese Pinyin**), plus **Manual Candidate Search** and **Paste / Edit Lyrics**.
- **Audiophile Playback Engine:** Gapless playback (`just_audio` / ExoPlayer + `audio_service`), 5-Band Equalizer, ReplayGain (`Track` / `Album` + pre-amp + anti-clipping), fade-out Sleep Timer, drag-to-reorder Queue, and waveform/thin-line seekbars.
- **Folder-First Library & 2×2 Auto-Collage Playlists:** Browse by Tracks, Albums, Artists, or Folders (with hide/exclude folder controls & minimum duration filter), Smart Playlists (*Favorites*, *Recently Played*, *Most Played*), custom user playlists with automatic 2×2 artwork collages or custom covers, `.m3u8`/`.pls`/`.xspf` import/export, and validated JSON backup & restore.
- **5 Theme-Synced Android Home Screen Widgets:**
  1. **Sonea Micro Pill (`4×1`)** — Compact capsule bar with artwork, live wave, and transport controls.
  2. **Sonea Studio Card (`4×2`)** — Large artwork, real format badge (`FLAC`, `OPUS`, `MP3`), live wave, shuffle, and transport controls.
  3. **Sonea Cover Tile (`2×2`)** — Artwork-first square tile with scrim controls and quick launch.
  4. **Sonea Up Next Desk (`4×3`)** — Active playback controls plus next 3 tappable queue tracks.
  5. **Sonea Quick Mix Dock (`4×2`)** — One-tap Shuffle All card, Play/Pause, and 3 playlist shortcuts.
- **Privacy & Security by Design:** Zero telemetry, HTTPS-only outbound requests (`usesCleartextTraffic="false"`, `rustls-tls`), strict host allowlists, 100% parameterized SQLite queries, canonical path validation, and `allowBackup="false"`.

### Screenshots

| Theme Gallery (Sanzo Wada) | Library & Folders | Playlists & 2×2 Collage | Now Playing & Synced Lyrics | Android Widgets |
| :---: | :---: | :---: | :---: | :---: |
| `docs/screenshots/themes.png` | `docs/screenshots/library.png` | `docs/screenshots/playlists.png` | `docs/screenshots/now_playing.png` | `docs/screenshots/widgets.png` |

### Building & Development

#### Prerequisites

- Flutter SDK (`>= 3.29`) & Dart SDK
- Rust toolchain (`stable`) with Android targets (`aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android`)
- Android SDK & NDK (`28.2.13676358`)
- `flutter_rust_bridge_codegen` (`2.11.1`, only needed when changing Rust FFI signatures)

#### Commands

```bash
# Install Dart dependencies
flutter pub get

# Regenerate FRB bindings (only after editing Rust pub fn signatures)
flutter_rust_bridge_codegen generate

# Rust tests & strict Clippy lints
cargo test --manifest-path rust/Cargo.toml
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings

# Flutter static analysis & test suite
flutter analyze
flutter test

# Build release APK (ARM64 or split-per-abi)
flutter build apk --release --target-platform android-arm64
# or:
flutter build apk --release --split-per-abi
```

Output APKs are generated in `build/app/outputs/flutter-apk/`.

---

<a id="türkçe"></a>
## Türkçe

### Genel Bakış

**Sonea**, akıcı 120Hz Flutter arayüzünü (`package:material_ui` + Riverpod) yerel olarak derlenmiş Rust çekirdeği (`rust_lib_sonea` / `flutter_rust_bridge 2.11.1`) ile birleştiren; hızlı yerel arşiv taraması, boşluksuz (gapless) yüksek kaliteli oynatma, senkronize öncelikli karaoke şarkı sözleri ve özenli tipografi sunan — **reklamsız, takipçisiz ve tamamen çevrimdışı öncelikli** bir Android müzik çalardır.

### Öne Çıkan Özellikler

- **Hibrit Flutter + Rust 120Hz Mimarisi:** Çok iş parçacıklı artımlı ses tarayıcısı (`lofty` + WAL modlu gömülü `rusqlite`), canlı ilerleme akışı, SHA-256 tekilleştirmeli kapak önbelleği, RAM dostu ölçekli görsel çözme ve `FLAC`, `OPUS`, `MP3`, `M4A`, `AAC`, `OGG`, `WAV`, `AIFF`, `WV` formatlarında Türkçe/Unicode uyumlu anlık arama.
- **10 Çift Modlu (Karanlık + Aydınlık) Sanzo Wada 4-Renkli Tema ve Özel Tipografi:** Sanzo Wada'nın *A Dictionary of Color Combinations* (*Haishoku Soukan*, 1933–34) eserinden seçilen 10 tasarım paleti (**Kuro & Asagi**, **Taisho Avant-Garde**, **Showa Studio**, **Kenpou Vinyl**, **Kachi Indigo**, **Tetsu Jade**, **Beni Vermilion**, **Washi Moss**, **Sakura Mineral**, **Kyoto Amber**); bağımsız `Sistem | Aydınlık | Karanlık` modu, WCAG AA kontrastı, her temaya özel yazı tipi eşleşmesi ve ayrı **Tema Galerisi** ekranı.
- **6 Sağlayıcılı Senkronize Öncelikli Karaoke Şarkı Sözü Motoru:**
  - Önce yerel kaynaklar (SQLite önbelleği → yan `.lrc`/`.txt` → gömülü ses etiketleri), ardından düz metnin senkronize `.lrc` sonuçlarını engellemediği katı **senkronize öncelikli** HTTPS kaskadı (**LRCLIB**, **KuGou**, **NetEase**, **Musixmatch**) ve yedek düz metin kaynakları (**Lyrics.ovh**, **Genius**).
  - Akıllı başlık/sanatçı temizliği (`- Topic`, `VEVO`, `~NARUTO OPENING`, `- TV Size`, CJK/Romaji ayrıştırma), dokunarak sarma destekli akıcı karaoke takibi, çevrimdışı Rust transliterasyonu (istek üzerine yüklenen `lindera` IPADIC ile **Japonca Romaji**, **Korece Hangul**, **Kiril**, **Yunanca**, **Çince Pinyin**), **Manuel Aday Arama** ve **Söz Yapıştır / Düzenle** sekmesi.
- **Odyofil Oynatma Motoru:** Boşluksuz (gapless) geçiş (`just_audio` + `audio_service`), 5-Bant Ekolayzır, ReplayGain (`Şarkı` / `Albüm` + ön-amfi + bozulma önleme), Uyku Zamanlayıcısı, sürükle-bırak Oynatma Sırası ve dalga formu / ince çizgi ilerleme çubuğu.
- **Klasör Odaklı Kütüphane ve 2×2 Otomatik Kolaj Listeler:** Şarkılar, Albümler, Sanatçılar ve Klasörler görünümleri (klasör gizleme ve minimum süre filtresi), Akıllı Listeler (*Favoriler*, *Son Çalınanlar*, *En Çok Dinlenenler*), 2×2 otomatik kapak kolajlı veya özel kapaklı çalma listeleri, `.m3u8`/`.pls`/`.xspf` içe-dışa aktarma ve doğrulamalı JSON yedekleme/geri yükleme.
- **Tema ile Senkronize 5 Android Ana Ekran Widget'ı:** *Sonea Micro Pill (4×1)*, *Sonea Studio Card (4×2)*, *Sonea Cover Tile (2×2)*, *Sonea Up Next Desk (4×3)* ve *Sonea Quick Mix Dock (4×2)* — seçili Sanzo Wada paletine ve Aydınlık/Karanlık moduna anında uyum sağlar.

### Geliştirme ve Derleme

```bash
# Bağımlılıkları yükle
flutter pub get

# Rust testleri ve Clippy denetimi
cargo test --manifest-path rust/Cargo.toml
cargo clippy --manifest-path rust/Cargo.toml --all-targets -- -D warnings

# Flutter statik analiz ve testler
flutter analyze
flutter test

# ARM64 yayın APK derlemesi
flutter build apk --release --target-platform android-arm64
```

---

## License / Lisans

- **Sonea** is licensed under the **GNU General Public License v3.0 (GPL-3.0)** — see [LICENSE](LICENSE).
- Third-party open-source libraries and bundled fonts are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
