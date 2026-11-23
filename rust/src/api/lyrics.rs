use crate::api::library::{get_connection, Track};
use crate::api::translit::transliterate_text;
use crate::frb_generated::StreamSink;
use lofty::file::TaggedFileExt;
use lofty::probe::Probe;
use lofty::tag::ItemKey;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};
use std::fs;
use std::io::Read;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use unicode_normalization::UnicodeNormalization;

const MAX_LRC_BYTES: usize = 512 * 1024; // 512 KiB
const MAX_HTTP_RESPONSE_BYTES: u64 = 2 * 1024 * 1024; // 2 MiB
const CONNECT_TIMEOUT_MS: u64 = 2_500;
const REQUEST_TIMEOUT_MS: u64 = 4_500;
const PLAIN_FALLBACK_TIMEOUT_MS: u64 = 3_500;
const RATE_LIMIT_COOLDOWN_SECS: u64 = 30;
const BULK_WORKER_COUNT: usize = 5;
const MIN_AUTO_MATCH_SCORE: f64 = 38.0;
const HIGH_CONFIDENCE_SYNCED_SCORE: f64 = 72.0;
const MUSIXMATCH_TOKEN_TTL_SECS: u64 = 20 * 60;

const SONEA_USER_AGENT: &str = "Sonea/1.0 (https://github.com/sonea-player/sonea)";
const BROWSER_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";
const NETEASE_REFERER: &str = "https://music.163.com/";
const MUSIXMATCH_APP_ID: &str = "web-desktop-app-v1.0";

static CANCEL_BULK_DOWNLOAD: AtomicBool = AtomicBool::new(false);
static MUSIXMATCH_TOKEN_CACHE: OnceLock<Mutex<Option<(String, Instant)>>> = OnceLock::new();
static SHARED_HTTP_CLIENT: OnceLock<Result<reqwest::blocking::Client, String>> = OnceLock::new();
static PLAIN_FALLBACK_HTTP_CLIENT: OnceLock<Result<reqwest::blocking::Client, String>> =
    OnceLock::new();

#[derive(Debug, Clone, Copy)]
enum ProviderId {
    Lrclib = 0,
    Kugou = 1,
    Netease = 2,
    Musixmatch = 3,
    LyricsOvh = 4,
    Genius = 5,
}

static PROVIDER_COOLDOWN_UNTIL: [AtomicU64; 6] = [
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
    AtomicU64::new(0),
];

fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn is_provider_in_cooldown_at(provider: ProviderId, now_secs: u64) -> bool {
    PROVIDER_COOLDOWN_UNTIL[provider as usize].load(Ordering::Relaxed) > now_secs
}

fn trigger_provider_cooldown_at(provider: ProviderId, now_secs: u64, duration_secs: u64) {
    let until = now_secs.saturating_add(duration_secs);
    PROVIDER_COOLDOWN_UNTIL[provider as usize].fetch_max(until, Ordering::Relaxed);
}

fn is_provider_in_cooldown(provider: ProviderId) -> bool {
    is_provider_in_cooldown_at(provider, now_epoch_secs())
}

fn note_http_status(provider: ProviderId, status: reqwest::StatusCode) {
    if status.as_u16() == 429 {
        trigger_provider_cooldown_at(provider, now_epoch_secs(), RATE_LIMIT_COOLDOWN_SECS);
    }
}

pub fn cancel_bulk_download() {
    CANCEL_BULK_DOWNLOAD.store(true, Ordering::SeqCst);
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricLine {
    pub time_ms: i64,
    pub text: String,
    pub transliterated: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricsResult {
    pub track_id: i64,
    pub lines: Vec<LyricLine>,
    pub plain_text: Option<String>,
    pub is_synced: bool,
    pub is_instrumental: bool,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricsCandidateDto {
    pub source: String,
    pub title: String,
    pub artist: String,
    pub duration_secs: Option<u32>,
    pub is_synced: bool,
    pub preview: String,
    pub synced_lrc: Option<String>,
    pub plain_lyrics: Option<String>,
}

#[flutter_rust_bridge::frb(unignore)]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BulkDownloadProgress {
    pub total: u32,
    pub processed: u32,
    pub success_synced: u32,
    pub success_plain: u32,
    pub instrumental_count: u32,
    pub not_found: u32,
    pub finished: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LyricsCoverageStats {
    pub total_tracks: u32,
    pub synced_count: u32,
    pub plain_count: u32,
    pub instrumental_count: u32,
    pub not_found_count: u32,
}

#[derive(Debug, Clone)]
struct ScoredCandidate {
    source: String,
    title: String,
    artist: String,
    duration_secs: Option<u32>,
    synced_lrc: Option<String>,
    plain_lyrics: Option<String>,
    is_synced: bool,
    is_instrumental: bool,
    score: f64,
}

#[derive(Debug, Clone)]
struct DecomposedQuery {
    raw_title: String,
    raw_artist: String,
    clean_title: String,
    clean_artist: String,
    album: String,
    title_variants: Vec<String>,
    duration_ms: i64,
    duration_secs: f64,
}

fn now_ts() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn is_offset_tag(trimmed: &str) -> Option<&str> {
    if trimmed.len() >= 9
        && trimmed.is_char_boundary(8)
        && trimmed.as_bytes()[..8].eq_ignore_ascii_case(b"[offset:")
        && trimmed.ends_with(']')
    {
        trimmed.get(8..trimmed.len() - 1)
    } else {
        None
    }
}

pub fn parse_lrc(lrc_text: &str) -> Vec<LyricLine> {
    if lrc_text.len() > MAX_LRC_BYTES {
        return Vec::new();
    }
    let clean_text = lrc_text.strip_prefix('\u{FEFF}').unwrap_or(lrc_text);
    let mut global_offset_ms: i64 = 0;

    for raw_line in clean_text.lines() {
        let trimmed = raw_line.trim();
        if let Some(val) = is_offset_tag(trimmed) {
            if let Ok(offset) = val.trim().parse::<i64>() {
                global_offset_ms = offset.clamp(-600_000, 600_000);
            }
        }
    }

    let mut lines = Vec::new();

    for raw_line in clean_text.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() || is_offset_tag(trimmed).is_some() {
            continue;
        }

        let mut timestamps = Vec::new();
        let mut text_start = 0;

        while text_start < trimmed.len() && trimmed.as_bytes()[text_start] == b'[' {
            let Some(rest) = trimmed.get(text_start..) else {
                break;
            };
            if let Some(close_idx) = rest.find(']') {
                if let Some(tag_content) = rest.get(1..close_idx) {
                    if let Some(time_ms) = parse_timestamp(tag_content) {
                        timestamps.push(time_ms);
                    }
                }
                text_start += close_idx + 1;
            } else {
                break;
            }
        }

        if timestamps.is_empty() {
            continue;
        }

        let raw_line_text = trimmed.get(text_start..).unwrap_or("").trim();
        let mut line_text = strip_inline_word_timestamps(raw_line_text);
        if line_text.is_empty() {
            line_text = "♪".to_string();
        }

        for time_ms in timestamps {
            let adjusted_time = time_ms.saturating_add(global_offset_ms).max(0);
            let transliterated = if line_text == "♪" {
                None
            } else {
                transliterate_text(&line_text)
            };
            lines.push(LyricLine {
                time_ms: adjusted_time,
                text: line_text.clone(),
                transliterated,
            });
        }
    }

    lines.sort_by_key(|l| l.time_ms);
    lines
}

fn parse_timestamp(tag: &str) -> Option<i64> {
    let mut parts = tag.split(':');
    let min_str = parts.next()?;
    let sec_str = parts.next()?;
    if parts.next().is_some() {
        return None;
    }

    let minutes: i64 = min_str.trim().parse().ok()?;
    if !(0..=600).contains(&minutes) {
        return None;
    }
    let mut sec_parts = sec_str.split(&['.', ','][..]);
    let seconds: i64 = sec_parts.next()?.trim().parse().ok()?;
    if !(0..=59).contains(&seconds) {
        return None;
    }

    let millis: i64 = if let Some(ms_str) = sec_parts.next() {
        let trimmed = ms_str.trim();
        if trimmed.len() == 1 {
            trimmed.parse::<i64>().ok()?.checked_mul(100)?
        } else if trimmed.len() == 2 {
            trimmed.parse::<i64>().ok()?.checked_mul(10)?
        } else if trimmed.len() == 3 {
            trimmed.parse::<i64>().ok()?
        } else {
            0
        }
    } else {
        0
    };

    minutes
        .checked_mul(60)?
        .checked_add(seconds)?
        .checked_mul(1000)?
        .checked_add(millis)
}

/// Strips enhanced-LRC inline word timestamps like `<00:12.40>` or `<1:05.120>`
/// while preserving non-timestamp angle brackets.
fn strip_inline_word_timestamps(line: &str) -> String {
    if !line.contains('<') {
        return line.trim().to_string();
    }
    let mut out = String::with_capacity(line.len());
    let mut cursor = 0usize;
    while cursor < line.len() {
        let rest = &line[cursor..];
        let Some(lt_rel) = rest.find('<') else {
            out.push_str(rest);
            break;
        };
        out.push_str(&rest[..lt_rel]);
        let tag_start = cursor + lt_rel;
        if let Some(gt_rel) = line[tag_start + 1..].find('>') {
            let inner = &line[tag_start + 1..tag_start + 1 + gt_rel];
            if parse_timestamp(inner).is_some() {
                cursor = tag_start + 1 + gt_rel + 1;
                continue;
            }
        }
        out.push('<');
        cursor = tag_start + 1;
    }

    // Collapse duplicate spaces left behind by stripped tags without altering CJK spacing.
    let mut normalized = String::with_capacity(out.len());
    let mut prev_space = false;
    for ch in out.trim().chars() {
        if ch.is_whitespace() {
            if !prev_space {
                normalized.push(' ');
                prev_space = true;
            }
        } else {
            normalized.push(ch);
            prev_space = false;
        }
    }
    normalized
}

fn build_lyrics_result_from_text(
    track_id: i64,
    text: &str,
    source: &str,
) -> Option<LyricsResult> {
    let clean_text = text.strip_prefix('\u{FEFF}').unwrap_or(text);
    if clean_text.trim().is_empty() || clean_text.len() > MAX_LRC_BYTES {
        return None;
    }
    let lines = parse_lrc(clean_text);
    let is_synced = !lines.is_empty();
    Some(LyricsResult {
        track_id,
        lines: if is_synced { lines } else { Vec::new() },
        plain_text: if is_synced {
            None
        } else {
            Some(clean_text.trim().to_string())
        },
        is_synced,
        is_instrumental: false,
        source: source.to_string(),
    })
}

/// Instant 0ms local heuristic detecting explicit instrumental/vocal-less tracks
/// and conservative classical instrumental forms while avoiding false flags on vocal tracks.
pub fn is_likely_instrumental_metadata(title: &str, album: &str, file_path: &str) -> bool {
    let stem = Path::new(file_path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    let norm_title = normalize_unicode_punctuation(title).to_lowercase();
    let norm_stem = normalize_unicode_punctuation(stem).to_lowercase();
    let norm_album = normalize_unicode_punctuation(album).to_lowercase();

    const EXPLICIT_MARKERS: &[&str] = &[
        "(instrumental)",
        "[instrumental]",
        "- instrumental",
        "(inst.)",
        "(inst)",
        "[inst.]",
        "[inst]",
        "off vocal",
        "off-vocal",
        "karaoke ver",
        "(karaoke)",
        "[karaoke]",
        "(bgm)",
        "[bgm]",
        "background music",
        "w/o vocals",
        "without vocals",
        "no vocals",
        "(piano ver.)",
        "(piano ver)",
        "(piano version)",
        "(orchestral ver.)",
        "(orchestral ver)",
        "(orchestral version)",
        "(music box)",
        "[music box]",
    ];

    for hay in [&norm_title, &norm_stem] {
        if EXPLICIT_MARKERS.iter().any(|m| hay.contains(m)) {
            return true;
        }
        // Check trailing standalone "instrumental" or "inst." word after dash/paren
        let trimmed = hay.trim();
        if trimmed.ends_with(" instrumental") || trimmed.ends_with(" inst.") {
            return true;
        }
    }

    // Conservative classical instrumental form detection
    const CLASSICAL_FORMS: &[&str] = &[
        "symphony no.",
        "piano concerto",
        "violin concerto",
        "cello concerto",
        "piano sonata",
        "violin sonata",
        "string quartet",
        "nocturne in ",
        "etude op.",
        "étude op.",
        "prelude op.",
        "prélude op.",
        "ballade no.",
        "mazurka op.",
        "impromptu op.",
    ];
    for hay in [&norm_title, &norm_stem] {
        if CLASSICAL_FORMS.iter().any(|m| hay.contains(m)) {
            return true;
        }
    }

    // Catalog number (BWV / KV / Op.) paired with classical movement/tempo markers
    let combined = format!("{norm_title} {norm_album}");
    let has_catalog = combined.contains("bwv ")
        || combined.contains("kv ")
        || combined.contains("op. ")
        || combined.contains("op.");
    if has_catalog {
        const CLASSICAL_MOVEMENTS: &[&str] = &[
            "allegro",
            "adagio",
            "andante",
            "presto",
            "largo",
            "moderato",
            "scherzo",
            "minuet",
            "menuetto",
            "rondo",
            "vivace",
            "sonata",
            "concerto",
            "symphony",
            "prelude",
            "fugue",
            "nocturne",
            "etude",
        ];
        if CLASSICAL_MOVEMENTS.iter().any(|m| combined.contains(m)) {
            return true;
        }
    }

    false
}

fn read_sidecar_lyrics(track_path: &Path, track_id: i64) -> Option<LyricsResult> {
    for ext in ["lrc", "txt"] {
        let candidate_path = track_path.with_extension(ext);
        if let Ok(meta) = fs::symlink_metadata(&candidate_path) {
            if meta.file_type().is_file() && meta.len() <= MAX_LRC_BYTES as u64 {
                if let Ok(text) = fs::read_to_string(&candidate_path) {
                    if let Some(res) = build_lyrics_result_from_text(track_id, &text, "sidecar") {
                        return Some(res);
                    }
                }
            }
        }
    }
    None
}

fn read_embedded_lyrics(track_path: &str, track_id: i64) -> Option<LyricsResult> {
    let probe = Probe::open(track_path).ok()?;
    let file = probe.read().ok()?;
    let tag = file.primary_tag().or_else(|| file.first_tag())?;
    let text = tag.get_string(ItemKey::Lyrics)?;
    build_lyrics_result_from_text(track_id, text, "embedded")
}

pub fn get_lyrics(
    db_path: String,
    track_id: i64,
    allow_network: bool,
    force_refresh: bool,
) -> Result<Option<LyricsResult>, String> {
    let conn = get_connection(&db_path)?;

    let track: Track = conn
        .query_row(
            "SELECT t.id,t.path,t.title,t.artist,t.album,t.album_artist,t.duration_ms,t.track_no,t.year,t.format,t.bitrate,t.sample_rate,t.bit_depth,t.channels,t.cover_path,t.file_modified,t.added_at,COALESCE(p.play_count,0),p.last_played,t.replaygain_track_gain,t.replaygain_album_gain,t.replaygain_track_peak FROM tracks t LEFT JOIN play_stats p ON p.track_id=t.id WHERE t.id=?1",
            [track_id],
            crate::api::library::map_track,
        )
        .map_err(|e| e.to_string())?;

    // Read existing cached lyrics once so we can serve immediately (when !force_refresh)
    // OR safely preserve them if a force-refresh upgrade encounters a transient failure.
    let existing_cached: Option<LyricsResult> = {
        let cached: Option<(String, Option<String>, Option<String>, String)> = conn
            .query_row(
                "SELECT source, synced_lrc, plain, status FROM lyrics WHERE track_id = ?1",
                [track_id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()
            .map_err(|e| e.to_string())?;

        cached.and_then(|(source, synced_lrc, plain, status)| {
            if status == "instrumental" {
                return Some(LyricsResult {
                    track_id,
                    lines: Vec::new(),
                    plain_text: None,
                    is_synced: false,
                    is_instrumental: true,
                    source,
                });
            }
            if status != "found" {
                return None;
            }
            if let Some(lrc) = synced_lrc {
                let lines = parse_lrc(&lrc);
                if !lines.is_empty() {
                    return Some(LyricsResult {
                        track_id,
                        lines,
                        plain_text: plain,
                        is_synced: true,
                        is_instrumental: false,
                        source,
                    });
                }
            }
            if let Some(plain_text) = plain {
                if !plain_text.trim().is_empty() {
                    return Some(LyricsResult {
                        track_id,
                        lines: Vec::new(),
                        plain_text: Some(plain_text),
                        is_synced: false,
                        is_instrumental: false,
                        source,
                    });
                }
            }
            None
        })
    };

    // Stage 0a: Local SQLite cache (zero-latency, preserves manual picks & instrumental flags)
    if !force_refresh {
        if let Some(cached_res) = existing_cached {
            return Ok(Some(cached_res));
        }
    }

    // Stage 0b: Sidecar .lrc / .txt & embedded audio tags (skip if force-refreshing from network)
    if !force_refresh {
        let track_path = Path::new(&track.path);
        if let Some(res) = read_sidecar_lyrics(track_path, track_id) {
            return Ok(Some(res));
        }

        if let Some(res) = read_embedded_lyrics(&track.path, track_id) {
            return Ok(Some(res));
        }

        // Stage 0c: Instant 0ms local instrumental metadata heuristic (zero network calls)
        if is_likely_instrumental_metadata(
            &track.title,
            track.album.as_deref().unwrap_or(""),
            &track.path,
        ) {
            let now = now_ts();
            let _ = conn.execute(
                "INSERT INTO lyrics(track_id, source, synced_lrc, plain, status, fetched_at, last_attempt_at)
                 VALUES(?1, 'heuristic', NULL, NULL, 'instrumental', ?2, ?2)
                 ON CONFLICT(track_id) DO UPDATE SET
                     source='heuristic', synced_lrc=NULL, plain=NULL,
                     status='instrumental', fetched_at=excluded.fetched_at, last_attempt_at=excluded.last_attempt_at",
                params![track_id, now],
            );
            return Ok(Some(LyricsResult {
                track_id,
                lines: Vec::new(),
                plain_text: None,
                is_synced: false,
                is_instrumental: true,
                source: "heuristic".to_string(),
            }));
        }
    }

    if !allow_network {
        return Ok(existing_cached);
    }

    // Stages 1-3: Fast-path LRCLIB exact -> Parallel 4-provider race -> Parallel plain fallback
    log::debug!(
        "[Lyrics] Running parallel synced-first cascade for track #{}",
        track.id
    );
    let fetched = fetch_six_provider_lyrics(&track)?;
    let now = now_ts();

    if let Some(best) = fetched {
        if best.is_instrumental {
            // Never overwrite existing verified synced lyrics with an instrumental flag
            if let Some(prev) = existing_cached.as_ref() {
                if prev.is_synced {
                    return Ok(existing_cached);
                }
            }
            conn.execute(
                "INSERT INTO lyrics(track_id, source, synced_lrc, plain, status, fetched_at, last_attempt_at)
                 VALUES(?1, ?2, NULL, NULL, 'instrumental', ?3, ?3)
                 ON CONFLICT(track_id) DO UPDATE SET
                     source=excluded.source, synced_lrc=NULL, plain=NULL,
                     status='instrumental', fetched_at=excluded.fetched_at, last_attempt_at=excluded.last_attempt_at",
                params![track_id, best.source, now],
            )
            .map_err(|e| e.to_string())?;

            return Ok(Some(LyricsResult {
                track_id,
                lines: Vec::new(),
                plain_text: None,
                is_synced: false,
                is_instrumental: true,
                source: best.source,
            }));
        }

        // Never downgrade previously cached synced lyrics to plain text on a refresh.
        if !best.is_synced {
            if let Some(prev) = existing_cached.as_ref() {
                if prev.is_synced {
                    return Ok(existing_cached);
                }
            }
        }

        let synced_val = best.synced_lrc.as_deref();
        let plain_val = best.plain_lyrics.as_deref();

        conn.execute(
            "INSERT INTO lyrics(track_id, source, synced_lrc, plain, status, fetched_at, last_attempt_at)
             VALUES(?1, ?2, ?3, ?4, 'found', ?5, ?5)
             ON CONFLICT(track_id) DO UPDATE SET
                 source=excluded.source, synced_lrc=excluded.synced_lrc, plain=excluded.plain,
                 status='found', fetched_at=excluded.fetched_at, last_attempt_at=excluded.last_attempt_at",
            params![track_id, best.source, synced_val, plain_val, now],
        )
        .map_err(|e| e.to_string())?;

        let lines = best
            .synced_lrc
            .as_deref()
            .map(parse_lrc)
            .unwrap_or_default();
        let is_synced = !lines.is_empty();

        Ok(Some(LyricsResult {
            track_id,
            lines,
            plain_text: best.plain_lyrics,
            is_synced,
            is_instrumental: false,
            source: best.source,
        }))
    } else if existing_cached.is_some() {
        // Preserve already-cached lyrics/instrumental status if force-refresh hits a transient error.
        let _ = conn.execute(
            "UPDATE lyrics SET last_attempt_at = ?1 WHERE track_id = ?2",
            params![now, track_id],
        );
        Ok(existing_cached)
    } else {
        conn.execute(
            "INSERT INTO lyrics(track_id, source, synced_lrc, plain, status, fetched_at, last_attempt_at)
             VALUES(?1, 'cascade', NULL, NULL, 'not_found', ?2, ?2)
             ON CONFLICT(track_id) DO UPDATE SET
                 status='not_found', last_attempt_at=excluded.last_attempt_at",
            params![track_id, now],
        )
        .map_err(|e| e.to_string())?;

        Ok(None)
    }
}

/// Bypasses any negative/stale cache and re-runs the full 6-provider online cascade.
pub fn refetch_track_lyrics(
    db_path: String,
    track_id: i64,
) -> Result<Option<LyricsResult>, String> {
    get_lyrics(db_path, track_id, true, true)
}

/// Searches LRCLIB, KuGou, NetEase, and Musixmatch and returns deduplicated,
/// score-sorted candidates for the in-app manual lyrics picker.
pub fn search_lyrics_candidates(
    query: String,
    artist: Option<String>,
    duration_secs: Option<u32>,
) -> Result<Vec<LyricsCandidateDto>, String> {
    let raw_query = sanitize_lyrics_param(&query);
    if raw_query.is_empty() {
        return Ok(Vec::new());
    }
    let raw_artist = artist
        .as_deref()
        .map(sanitize_lyrics_param)
        .unwrap_or_default();

    let dur_ms = i64::from(duration_secs.unwrap_or(0)) * 1000;
    let dq = decompose_query_parts(&raw_query, &raw_artist, "", "", dur_ms);

    let client = shared_http_client()?;

    // Run all 4 synced-capable providers CONCURRENTLY via std::thread::scope (~1s total)
    let (lrclib_res, kugou_res, netease_res, mxm_res) = std::thread::scope(|s| {
        let h_lrc = s.spawn(|| search_lrclib_candidates(client, &dq));
        let h_kg = s.spawn(|| search_kugou_candidates(client, &dq, 3));
        let h_ne = s.spawn(|| search_netease_candidates(client, &dq, 3));
        let h_mxm = s.spawn(|| fetch_musixmatch_candidate(client, &dq));
        (
            h_lrc.join().unwrap_or_default(),
            h_kg.join().unwrap_or_default(),
            h_ne.join().unwrap_or_default(),
            h_mxm.join().ok().flatten(),
        )
    });

    let mut candidates = Vec::new();
    candidates.extend(lrclib_res);
    candidates.extend(kugou_res);
    candidates.extend(netease_res);
    if let Some(mxm) = mxm_res {
        candidates.push(mxm);
    }

    // Manual picker shows singable lyrics candidates (exclude instrumental-only markers)
    candidates.retain(|c| !c.is_instrumental && (c.synced_lrc.is_some() || c.plain_lyrics.is_some()));

    candidates.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for c in candidates {
        let key = format!(
            "{}|{}|{}|{}",
            c.source,
            normalize_for_match(&c.title),
            normalize_for_match(&c.artist),
            c.is_synced
        );
        if !seen.insert(key) {
            continue;
        }
        let preview = build_lyrics_preview(c.synced_lrc.as_deref(), c.plain_lyrics.as_deref());
        if preview.is_empty() {
            continue;
        }
        out.push(LyricsCandidateDto {
            source: c.source,
            title: c.title,
            artist: c.artist,
            duration_secs: c.duration_secs,
            is_synced: c.is_synced,
            preview,
            synced_lrc: c.synced_lrc,
            plain_lyrics: c.plain_lyrics,
        });
        if out.len() >= 16 {
            break;
        }
    }

    Ok(out)
}

/// Persists user-selected or manually pasted lyrics into SQLite for [track_id].
pub fn save_custom_lyrics(
    db_path: String,
    track_id: i64,
    synced_lrc: Option<String>,
    plain_lyrics: Option<String>,
    source: String,
) -> Result<(), String> {
    let clean_synced = synced_lrc
        .map(|s| s.strip_prefix('\u{FEFF}').unwrap_or(&s).trim().to_string())
        .filter(|s| !s.is_empty());
    let clean_plain = plain_lyrics
        .map(|s| s.strip_prefix('\u{FEFF}').unwrap_or(&s).trim().to_string())
        .filter(|s| !s.is_empty());

    if clean_synced.is_none() && clean_plain.is_none() {
        return Err("Lyrics content cannot be empty".to_string());
    }
    if clean_synced
        .as_ref()
        .is_some_and(|s| s.len() > MAX_LRC_BYTES)
        || clean_plain
            .as_ref()
            .is_some_and(|s| s.len() > MAX_LRC_BYTES)
    {
        return Err("Lyrics content exceeds maximum allowed size".to_string());
    }

    let safe_source: String = source
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-' || *c == ':')
        .take(32)
        .collect();
    let final_source = if safe_source.is_empty() {
        "manual".to_string()
    } else {
        safe_source
    };

    let conn = get_connection(&db_path)?;
    let now = now_ts();
    conn.execute(
        "INSERT INTO lyrics(track_id, source, synced_lrc, plain, status, fetched_at, last_attempt_at)
         VALUES(?1, ?2, ?3, ?4, 'found', ?5, ?5)
         ON CONFLICT(track_id) DO UPDATE SET
             source=excluded.source, synced_lrc=excluded.synced_lrc, plain=excluded.plain,
             status='found', fetched_at=excluded.fetched_at, last_attempt_at=excluded.last_attempt_at",
        params![
            track_id,
            final_source,
            clean_synced.as_deref(),
            clean_plain.as_deref(),
            now
        ],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

// ============================================================================
// HTTP Models & Helpers
// ============================================================================

#[derive(Deserialize)]
struct LrclibResponse {
    #[serde(rename = "trackName")]
    track_name: Option<String>,
    #[serde(rename = "artistName")]
    artist_name: Option<String>,
    #[serde(rename = "syncedLyrics")]
    synced_lyrics: Option<String>,
    #[serde(rename = "plainLyrics")]
    plain_lyrics: Option<String>,
    duration: Option<f64>,
    instrumental: Option<bool>,
}

#[derive(Deserialize)]
struct KugouSearchRoot {
    candidates: Option<Vec<KugouCandidate>>,
}

#[derive(Deserialize)]
struct KugouCandidate {
    id: Option<String>,
    accesskey: Option<String>,
    song: Option<String>,
    singer: Option<String>,
    duration: Option<i64>,
}

#[derive(Deserialize)]
struct KugouDownloadRoot {
    content: Option<String>,
}

#[derive(Deserialize)]
struct NeteaseSearchRoot {
    result: Option<NeteaseSearchResult>,
}

#[derive(Deserialize)]
struct NeteaseSearchResult {
    songs: Option<Vec<NeteaseSong>>,
}

#[derive(Deserialize)]
struct NeteaseSong {
    id: i64,
    name: Option<String>,
    artists: Option<Vec<NeteaseArtist>>,
    duration: Option<i64>,
}

#[derive(Deserialize)]
struct NeteaseArtist {
    name: Option<String>,
}

#[derive(Deserialize)]
struct NeteaseLyricRoot {
    lrc: Option<NeteaseLyricBody>,
    nolyric: Option<bool>,
}

#[derive(Deserialize)]
struct NeteaseLyricBody {
    lyric: Option<String>,
}

#[derive(Deserialize)]
struct LyricsOvhResponse {
    lyrics: Option<String>,
}

fn shared_http_client() -> Result<&'static reqwest::blocking::Client, String> {
    SHARED_HTTP_CLIENT
        .get_or_init(|| {
            reqwest::blocking::Client::builder()
                .connect_timeout(Duration::from_millis(CONNECT_TIMEOUT_MS))
                .timeout(Duration::from_millis(REQUEST_TIMEOUT_MS))
                .https_only(true)
                .pool_max_idle_per_host(8)
                .user_agent(SONEA_USER_AGENT)
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn shared_plain_fallback_client() -> Result<&'static reqwest::blocking::Client, String> {
    PLAIN_FALLBACK_HTTP_CLIENT
        .get_or_init(|| {
            reqwest::blocking::Client::builder()
                .connect_timeout(Duration::from_millis(CONNECT_TIMEOUT_MS))
                .timeout(Duration::from_millis(PLAIN_FALLBACK_TIMEOUT_MS))
                .https_only(true)
                .pool_max_idle_per_host(6)
                .user_agent(SONEA_USER_AGENT)
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn sanitize_lyrics_param(input: &str) -> String {
    input
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect::<String>()
        .trim()
        .to_string()
}

fn read_bounded_bytes(resp: reqwest::blocking::Response) -> Option<Vec<u8>> {
    if !resp.status().is_success() {
        return None;
    }
    if resp
        .content_length()
        .is_some_and(|len| len > MAX_HTTP_RESPONSE_BYTES)
    {
        return None;
    }
    let mut buf = Vec::new();
    if resp
        .take(MAX_HTTP_RESPONSE_BYTES + 1)
        .read_to_end(&mut buf)
        .is_err()
    {
        return None;
    }
    if (buf.len() as u64) > MAX_HTTP_RESPONSE_BYTES {
        return None;
    }
    Some(buf)
}

fn read_bounded_json<T: for<'de> Deserialize<'de>>(
    resp: reqwest::blocking::Response,
) -> Option<T> {
    let buf = read_bounded_bytes(resp)?;
    serde_json::from_slice(&buf).ok()
}

/// Zero-dependency RFC 4648 Base64 decoder (ignores ASCII whitespace).
fn decode_base64(input: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity((input.len() * 3) / 4);
    let mut quad = [0u8; 4];
    let mut q_len = 0usize;

    for b in input.bytes() {
        if b.is_ascii_whitespace() {
            continue;
        }
        let val = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' => 64,
            _ => return None,
        };
        quad[q_len] = val;
        q_len += 1;
        if q_len == 4 {
            if quad[0] == 64 || quad[1] == 64 {
                return None;
            }
            out.push((quad[0] << 2) | (quad[1] >> 4));
            if quad[2] != 64 {
                out.push((quad[1] << 4) | (quad[2] >> 2));
                if quad[3] != 64 {
                    out.push((quad[2] << 6) | quad[3]);
                }
            }
            q_len = 0;
        }
    }

    if q_len == 2 {
        out.push((quad[0] << 2) | (quad[1] >> 4));
    } else if q_len == 3 {
        out.push((quad[0] << 2) | (quad[1] >> 4));
        out.push((quad[1] << 4) | (quad[2] >> 2));
    } else if q_len == 1 {
        return None;
    }

    Some(out)
}

// ============================================================================
// Smarter Metadata Normalization, Splitting & Script Variants
// ============================================================================

fn normalize_unicode_punctuation(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '（' => out.push('('),
            '）' => out.push(')'),
            '【' | '［' | '『' | '「' => out.push('['),
            '】' | '］' | '』' | '」' => out.push(']'),
            '’' | '‘' | '´' => out.push('\''),
            '“' | '”' => out.push('"'),
            '\u{3000}' => out.push(' '),
            '～' => out.push('~'),
            '－' | '–' | '—' => out.push('-'),
            other => out.push(other),
        }
    }
    out
}

fn strip_audio_extension(input: &str) -> &str {
    const AUDIO_EXTS: &[&str] = &[
        ".mp3", ".flac", ".m4a", ".opus", ".ogg", ".wav", ".aac", ".wma", ".aiff", ".wv",
    ];
    let lower = input.to_ascii_lowercase();
    for ext in AUDIO_EXTS {
        if lower.ends_with(ext) && input.len() > ext.len() {
            let cut = input.len() - ext.len();
            if input.is_char_boundary(cut) {
                return &input[..cut];
            }
        }
    }
    input
}

fn strip_leading_track_number(input: &str) -> &str {
    let trimmed = input.trim_start();

    // Handle bracketed track number like "[01] Song" or "(01) Song"
    if (trimmed.starts_with('[') || trimmed.starts_with('(')) && trimmed.len() > 4 {
        let close = if trimmed.starts_with('[') { ']' } else { ')' };
        if let Some(close_idx) = trimmed.find(close) {
            if let Some(inside) = trimmed.get(1..close_idx) {
                let inner = inside.trim();
                if !inner.is_empty()
                    && inner.len() <= 3
                    && inner.bytes().all(|b| b.is_ascii_digit())
                {
                    let rest = trimmed[close_idx + 1..].trim_start();
                    if !rest.is_empty() {
                        return rest;
                    }
                }
            }
        }
    }

    let bytes = trimmed.as_bytes();
    let mut i = 0;

    while i < bytes.len() && bytes[i].is_ascii_digit() && i < 2 {
        i += 1;
    }
    if i == 0 {
        return trimmed;
    }
    // Support disc-track like "1-02"
    if i < bytes.len() && bytes[i] == b'-' {
        let mut j = i + 1;
        while j < bytes.len() && bytes[j].is_ascii_digit() && (j - i) <= 3 {
            j += 1;
        }
        if j > i + 1 {
            i = j;
        }
    }

    let mut k = i;
    while k < bytes.len() && bytes[k] == b' ' {
        k += 1;
    }
    if k < bytes.len() && matches!(bytes[k], b'-' | b'.' | b'_' | b')') {
        k += 1;
        while k < bytes.len() && matches!(bytes[k], b' ' | b'-' | b'_') {
            k += 1;
        }
        if k < trimmed.len() && trimmed.is_char_boundary(k) {
            return &trimmed[k..];
        }
    }

    trimmed
}

fn clean_artist_channel_suffixes(artist: &str) -> String {
    let mut s = sanitize_lyrics_param(artist);
    s = normalize_unicode_punctuation(&s);

    const SUFFIXES: &[&str] = &[
        " - topic",
        "- topic",
        " official channel",
        " official music",
        " official",
        " records",
        " music",
        " vevo",
        "vevo",
    ];

    loop {
        let lower = s.to_lowercase();
        let mut stripped = false;
        for suffix in SUFFIXES {
            if lower.ends_with(suffix) && s.len() > suffix.len() {
                let cut = s.len() - suffix.len();
                if s.is_char_boundary(cut) {
                    let candidate = s[..cut].trim();
                    if candidate.chars().count() >= 2 {
                        s = candidate.to_string();
                        stripped = true;
                        break;
                    }
                }
            }
        }
        if !stripped {
            break;
        }
    }

    s.trim().to_string()
}

fn split_artist_title_from_string(raw: &str) -> Option<(String, String)> {
    const SEPARATORS: &[&str] = &[" - ", " – ", " — ", " | "];
    for sep in SEPARATORS {
        if let Some((left, right)) = raw.split_once(sep) {
            let l = left.trim();
            let r = right.trim();
            if !l.is_empty() && !r.is_empty() {
                return Some((l.to_string(), r.to_string()));
            }
        }
    }
    None
}

fn is_cjk_char(c: char) -> bool {
    matches!(
        c,
        '\u{3040}'..='\u{30FF}' // Hiragana & Katakana
            | '\u{3400}'..='\u{4DBF}' // CJK Ext A
            | '\u{4E00}'..='\u{9FFF}' // CJK Unified
            | '\u{AC00}'..='\u{D7AF}' // Hangul Syllables
            | '\u{F900}'..='\u{FAFF}' // CJK Compatibility
    )
}

fn is_latin_letter(c: char) -> bool {
    c.is_alphabetic() && !is_cjk_char(c)
}

/// If a title mixes CJK/Japanese/Korean with Latin/Romaji
/// (e.g. `"残響散歌 (Zankyosanka)"` or `"Gurenge / 紅蓮華"`),
/// returns both the CJK-focused and Latin-focused query variants.
fn extract_cjk_latin_variants(title: &str) -> Vec<String> {
    let norm = normalize_unicode_punctuation(title);
    let has_cjk = norm.chars().any(is_cjk_char);
    let has_latin = norm.chars().any(is_latin_letter);
    if !has_cjk || !has_latin {
        return Vec::new();
    }

    let mut variants = Vec::new();
    let mut push_unique = |s: String| {
        let cleaned = clean_for_lyrics_query(&s);
        if cleaned.chars().count() >= 2
            && !variants.iter().any(|v: &String| v.eq_ignore_ascii_case(&cleaned))
        {
            variants.push(cleaned);
        }
    };

    // Split on '/' or '(' / '[' chunks and group CJK vs Latin segments
    let mut cjk_parts = Vec::new();
    let mut latin_parts = Vec::new();

    for segment in norm.split(&['/', '(', ')', '[', ']', '|'][..]) {
        let seg = segment.trim();
        if seg.is_empty() {
            continue;
        }
        let seg_cjk = seg.chars().any(is_cjk_char);
        let seg_latin = seg.chars().any(is_latin_letter);
        if seg_cjk && !seg_latin {
            cjk_parts.push(seg);
        } else if seg_latin && !seg_cjk {
            latin_parts.push(seg);
        }
    }

    if !cjk_parts.is_empty() {
        push_unique(cjk_parts.join(" "));
    }
    if !latin_parts.is_empty() {
        push_unique(latin_parts.join(" "));
    }

    variants
}

fn is_uninformative_title(title: &str) -> bool {
    let lower = title.trim().to_lowercase();
    lower.is_empty()
        || lower == "unknown"
        || lower == "untitled"
        || lower == "audio"
        || lower.starts_with("track ")
        || lower.starts_with("audiotrack")
}

fn decompose_query_parts(
    track_title: &str,
    track_artist: &str,
    track_album: &str,
    track_path: &str,
    duration_ms: i64,
) -> DecomposedQuery {
    let mut raw_artist = clean_artist_channel_suffixes(track_artist);
    if is_unknown_artist(&raw_artist) {
        raw_artist.clear();
    }

    let mut raw_title = sanitize_lyrics_param(track_title);

    // Fallback to filename stem when title is empty/uninformative
    if (is_uninformative_title(&raw_title) || raw_artist.is_empty()) && !track_path.is_empty() {
        if let Some(stem) = Path::new(track_path)
            .file_stem()
            .and_then(|s| s.to_str())
        {
            let normalized_stem = normalize_unicode_punctuation(stem);
            let cleaned_stem = strip_leading_track_number(&normalized_stem).trim();
            if is_uninformative_title(&raw_title) && !cleaned_stem.is_empty() {
                raw_title = cleaned_stem.to_string();
            } else if raw_artist.is_empty() {
                if let Some((stem_art, stem_title)) = split_artist_title_from_string(cleaned_stem) {
                    let clean_art = clean_artist_channel_suffixes(&stem_art);
                    if !is_unknown_artist(&clean_art) {
                        raw_artist = clean_art;
                        if normalize_for_match(&raw_title) == normalize_for_match(cleaned_stem) {
                            raw_title = stem_title;
                        }
                    }
                }
            }
        }
    }

    // Split "Artist - Title" / "Artist – Title" / "Artist | Title" when artist is missing
    if raw_artist.is_empty() {
        let stripped_num = strip_leading_track_number(&raw_title);
        if let Some((art_part, title_part)) = split_artist_title_from_string(stripped_num) {
            let cleaned_art = clean_artist_channel_suffixes(&art_part);
            if !is_unknown_artist(&cleaned_art) {
                raw_artist = cleaned_art;
                raw_title = title_part;
            }
        }
    }

    let clean_title = clean_for_lyrics_query(&raw_title);
    let clean_artist = clean_for_lyrics_query(&raw_artist);
    let effective_title = if clean_title.is_empty() {
        raw_title.clone()
    } else {
        clean_title
    };

    let mut title_variants = Vec::new();
    if !effective_title.is_empty() {
        title_variants.push(effective_title.clone());
    }
    for v in extract_cjk_latin_variants(&raw_title) {
        if !title_variants
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(&v))
        {
            title_variants.push(v);
        }
    }
    if !raw_title.is_empty()
        && !title_variants
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(&raw_title))
    {
        title_variants.push(raw_title.clone());
    }

    let album = sanitize_lyrics_param(track_album);
    let duration_secs = if duration_ms > 0 {
        (duration_ms / 1000) as f64
    } else {
        0.0
    };

    DecomposedQuery {
        raw_title,
        raw_artist,
        clean_title: effective_title,
        clean_artist,
        album,
        title_variants,
        duration_ms: duration_ms.max(0),
        duration_secs,
    }
}

fn is_noise_bracket_content(lower: &str) -> bool {
    const SUBSTRING_TAGS: &[&str] = &[
        "official video",
        "official music video",
        "official audio",
        "music video",
        "lyric video",
        "lyrics",
        "official",
        "audio",
        "remastered",
        "remaster",
        "tv size",
        "tv ver",
        "full ver",
        "full version",
        "short ver",
        "game size",
        "anime ver",
        "radio edit",
        "single version",
        "album version",
        "bonus track",
        "visualizer",
        "explicit",
        "feat.",
        "ft.",
        "featuring",
        "prod.",
        "video",
        "live",
    ];
    if SUBSTRING_TAGS.iter().any(|tag| lower.contains(tag)) {
        return true;
    }

    const WORD_TAGS: &[&str] = &["hd", "4k", "hq", "mv", "pv", "ost", "op", "ed"];
    lower
        .split(|c: char| !c.is_alphanumeric())
        .any(|word| WORD_TAGS.contains(&word))
}

pub fn clean_for_lyrics_query(input: &str) -> String {
    let sanitized = sanitize_lyrics_param(input);
    let normalized = normalize_unicode_punctuation(&sanitized);
    let no_ext = strip_audio_extension(&normalized);
    let mut cleaned = strip_leading_track_number(no_ext).to_string();

    let mut result = String::with_capacity(cleaned.len());
    let mut in_paren = false;
    let mut open_char = '(';
    let mut paren_buf = String::new();

    for c in cleaned.chars() {
        if (c == '(' || c == '[') && !in_paren {
            in_paren = true;
            open_char = c;
            paren_buf.clear();
        } else if (c == ')' || c == ']') && in_paren {
            in_paren = false;
            let lower = paren_buf.to_lowercase();
            if !is_noise_bracket_content(&lower) && !paren_buf.trim().is_empty() {
                let close_char = if open_char == '[' { ']' } else { ')' };
                result.push(open_char);
                result.push_str(paren_buf.trim());
                result.push(close_char);
            }
            paren_buf.clear();
        } else if in_paren {
            paren_buf.push(c);
        } else {
            result.push(c);
        }
    }

    if in_paren {
        result.push(open_char);
        result.push_str(&paren_buf);
    }

    cleaned = result;

    // Strip tilde anime/OST subtitle suffixes like "GO!!! ~NARUTO OPENING" or "Blue Bird ~Naruto OP~"
    // when preceded by whitespace and preserving at least 2 characters of core title.
    if let Some(tilde_idx) = cleaned.find('~') {
        if tilde_idx >= 2 && cleaned.is_char_boundary(tilde_idx) {
            let prefix = cleaned[..tilde_idx].trim();
            if prefix.chars().count() >= 2 {
                cleaned = prefix.to_string();
            }
        }
    }

    // Strip dash edition / anime OST suffixes like "- TV Size", "- Opening Theme", "- Remastered"
    const DASH_NOISE_SUFFIXES: &[&str] = &[
        "tv size",
        "tv ver",
        "opening theme",
        "opening",
        "ending theme",
        "ending",
        "full ver",
        "full version",
        "short ver",
        "game size",
        "anime ver",
        "radio edit",
        "remastered",
        "remaster",
        "single version",
        "album version",
        "ost",
        "op",
        "ed",
    ];
    if let Some(dash_idx) = cleaned.rfind(" - ") {
        if dash_idx >= 2 && cleaned.is_char_boundary(dash_idx) {
            let suffix_lower = cleaned[dash_idx + 3..].trim().to_lowercase();
            let is_noise = DASH_NOISE_SUFFIXES.iter().any(|tag| {
                suffix_lower == *tag
                    || suffix_lower.starts_with(&format!("{tag} "))
                    || suffix_lower.starts_with(&format!("{tag}."))
                    || suffix_lower.ends_with(&format!(" {tag}"))
                    || suffix_lower.contains(&format!(" {tag} "))
            });
            if is_noise {
                let prefix = cleaned[..dash_idx].trim();
                if prefix.chars().count() >= 2 {
                    cleaned = prefix.to_string();
                }
            }
        }
    }

    let lower_cleaned = cleaned.to_lowercase();
    for marker in [" feat. ", " ft. ", " feat ", " ft ", " featuring "] {
        if let Some(idx) = lower_cleaned.find(marker) {
            if cleaned.is_char_boundary(idx) {
                cleaned.truncate(idx);
                break;
            }
        }
    }

    cleaned
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_matches(|c: char| c == '-' || c == '|' || c == '~' || c.is_whitespace())
        .to_string()
}

fn is_unknown_artist(art: &str) -> bool {
    let lower = art.trim().to_lowercase();
    lower.is_empty()
        || lower == "unknown artist"
        || lower == "bilinmeyen sanatçı"
        || lower == "<unknown>"
        || lower == "unknown"
        || lower == "bilinmeyen"
        || lower == "various artists"
        || lower == "va"
}

fn normalize_for_match(input: &str) -> String {
    let mut mapped = String::with_capacity(input.len());
    for c in normalize_unicode_punctuation(input).chars() {
        match c {
            'İ' | 'I' | 'ı' => mapped.push('i'),
            other => mapped.push(other),
        }
    }
    let lowered = mapped.to_lowercase();
    let stripped: String = lowered
        .nfd()
        .filter(|&c| !('\u{0300}'..='\u{036F}').contains(&c))
        .collect();
    let nfc: String = stripped.nfc().collect();

    let mut out = String::with_capacity(nfc.len());
    let mut last_space = true;
    for c in nfc.chars() {
        if c.is_alphanumeric() {
            out.push(c);
            last_space = false;
        } else if !last_space {
            out.push(' ');
            last_space = true;
        }
    }
    out.trim().to_string()
}

fn char_bigrams(s: &str) -> HashSet<(char, char)> {
    let chars: Vec<char> = s.chars().filter(|c| !c.is_whitespace()).collect();
    let mut set = HashSet::new();
    for pair in chars.windows(2) {
        set.insert((pair[0], pair[1]));
    }
    set
}

fn text_similarity(a: &str, b: &str) -> f64 {
    let na = normalize_for_match(a);
    let nb = normalize_for_match(b);
    if na.is_empty() || nb.is_empty() {
        return 0.0;
    }
    if na == nb {
        return 1.0;
    }

    // Space-collapsed exact equality handles spacing differences like "YonezuKenshi" vs "Yonezu Kenshi"
    let ca: String = na.chars().filter(|c| !c.is_whitespace()).collect();
    let cb: String = nb.chars().filter(|c| !c.is_whitespace()).collect();
    if !ca.is_empty() && ca == cb {
        return 0.98;
    }

    let words_a: HashSet<&str> = na.split_whitespace().collect();
    let words_b: HashSet<&str> = nb.split_whitespace().collect();
    let word_sim = if !words_a.is_empty() && !words_b.is_empty() {
        let inter = words_a.intersection(&words_b).count() as f64;
        let union = words_a.union(&words_b).count() as f64;
        if union > 0.0 {
            inter / union
        } else {
            0.0
        }
    } else {
        0.0
    };

    // Only grant substring similarity boost when the shorter string is substantial (>= 4 chars)
    // so short titles/tokens like "99" or "go" never inflate against "99 problems" or "go your own way".
    let min_chars = na.chars().count().min(nb.chars().count());
    let sub_sim = if min_chars >= 4 && (na.contains(&nb) || nb.contains(&na)) {
        let max_chars = na.chars().count().max(nb.chars().count()) as f64;
        if max_chars > 0.0 {
            (0.65 + 0.35 * (min_chars as f64 / max_chars)).min(0.96)
        } else {
            0.0
        }
    } else {
        0.0
    };

    let bg_a = char_bigrams(&na);
    let bg_b = char_bigrams(&nb);
    let bigram_sim = if !bg_a.is_empty() && !bg_b.is_empty() {
        let inter = bg_a.intersection(&bg_b).count() as f64;
        (2.0 * inter) / ((bg_a.len() + bg_b.len()) as f64)
    } else {
        0.0
    };

    word_sim.max(sub_sim).max(bigram_sim * 0.95)
}

/// Splits multi-artist strings on `,`, `&`, `;`, `/`, `feat.`, `ft.`, `x`, `×`, etc.
fn split_artist_tokens(raw: &str) -> Vec<String> {
    let norm = normalize_unicode_punctuation(raw);
    let mut work = norm;
    for sep in [
        " feat. ",
        " ft. ",
        " feat ",
        " ft ",
        " featuring ",
        " with ",
        " vs. ",
        " vs ",
        " x ",
        " × ",
        " & ",
        " + ",
        " / ",
        "、",
        "・",
    ] {
        // Case-insensitive split replacement for ASCII markers
        let lower = work.to_lowercase();
        if lower.contains(sep) {
            let mut replaced = String::with_capacity(work.len());
            let mut rest = work.as_str();
            let mut rest_lower = lower.as_str();
            while let Some(idx) = rest_lower.find(sep) {
                if rest.is_char_boundary(idx) && rest.is_char_boundary(idx + sep.len()) {
                    replaced.push_str(&rest[..idx]);
                    replaced.push('\u{001F}');
                    rest = &rest[idx + sep.len()..];
                    rest_lower = &rest_lower[idx + sep.len()..];
                } else {
                    break;
                }
            }
            replaced.push_str(rest);
            work = replaced;
        }
    }

    let mut tokens = Vec::new();
    for part in work.split(['\u{001F}', ',', ';', '&', '/']) {
        let cleaned = clean_artist_channel_suffixes(part);
        let trimmed = cleaned.trim();
        if !trimmed.is_empty()
            && !is_unknown_artist(trimmed)
            && !tokens.iter().any(|t: &String| t.eq_ignore_ascii_case(trimmed))
        {
            tokens.push(trimmed.to_string());
        }
    }
    tokens
}

fn expand_match_forms(raw: &str) -> Vec<String> {
    let mut forms = Vec::new();
    let base = normalize_for_match(raw);
    if !base.is_empty() {
        forms.push(base);
    }
    if let Some(translit) = transliterate_text(raw) {
        let norm_t = normalize_for_match(&translit);
        if !norm_t.is_empty() && !forms.contains(&norm_t) {
            forms.push(norm_t);
        }
    }
    forms
}

/// Computes transliteration-aware, multi-artist similarity in `0.0..=1.0`.
/// Handles Japanese/CJK <-> Romaji artist names (e.g. "米津玄師" <-> "Yonezu Kenshi",
/// "ヒトリエ" <-> "Hitorie") and multi-artist collaborations cleanly.
fn artist_similarity(cand_artist: &str, target_artist: &str) -> f64 {
    let clean_cand = clean_artist_channel_suffixes(cand_artist);
    let clean_target = clean_artist_channel_suffixes(target_artist);
    if clean_cand.is_empty()
        || clean_target.is_empty()
        || is_unknown_artist(&clean_cand)
        || is_unknown_artist(&clean_target)
    {
        return 0.0;
    }

    let mut cand_forms = expand_match_forms(&clean_cand);
    for tok in split_artist_tokens(&clean_cand) {
        for form in expand_match_forms(&tok) {
            if !cand_forms.contains(&form) {
                cand_forms.push(form);
            }
        }
    }

    let mut target_forms = expand_match_forms(&clean_target);
    for tok in split_artist_tokens(&clean_target) {
        for form in expand_match_forms(&tok) {
            if !target_forms.contains(&form) {
                target_forms.push(form);
            }
        }
    }

    let mut best = 0.0_f64;
    for cf in &cand_forms {
        for tf in &target_forms {
            let sim = text_similarity(cf, tf);
            if sim > best {
                best = sim;
                if best >= 1.0 {
                    return 1.0;
                }
            }
        }
    }
    best
}

fn best_title_similarity(cand_title: &str, variants: &[String]) -> f64 {
    let clean_cand = clean_for_lyrics_query(cand_title);
    let mut cand_forms = expand_match_forms(if clean_cand.is_empty() {
        cand_title
    } else {
        &clean_cand
    });
    for f in expand_match_forms(cand_title) {
        if !cand_forms.contains(&f) {
            cand_forms.push(f);
        }
    }

    let mut best = 0.0_f64;
    for v in variants {
        let v_forms = expand_match_forms(v);
        for cf in &cand_forms {
            for vf in &v_forms {
                let sim = text_similarity(cf, vf);
                if sim > best {
                    best = sim;
                }
            }
        }
    }
    best
}

fn is_short_title(clean_title: &str) -> bool {
    let norm = normalize_for_match(clean_title);
    let alnum_count = norm.chars().filter(|c| c.is_alphanumeric()).count();
    let word_count = norm.split_whitespace().count();
    alnum_count <= 4 || word_count <= 1
}

fn has_exact_normalized_title_match(cand_title: &str, dq: &DecomposedQuery) -> bool {
    let clean_cand = clean_for_lyrics_query(cand_title);
    let cand_forms = expand_match_forms(if clean_cand.is_empty() {
        cand_title
    } else {
        &clean_cand
    });
    for v in &dq.title_variants {
        for vf in expand_match_forms(v) {
            if cand_forms.iter().any(|cf| cf == &vf) {
                return true;
            }
        }
    }
    false
}

fn has_clean_substring_title_match(cand_title: &str, dq: &DecomposedQuery) -> bool {
    let clean_cand = normalize_for_match(&clean_for_lyrics_query(cand_title));
    let clean_target = normalize_for_match(&dq.clean_title);
    if clean_cand.chars().count() < 4 || clean_target.chars().count() < 4 {
        return false;
    }
    clean_cand.contains(&clean_target) || clean_target.contains(&clean_cand)
}

fn has_known_artist(dq: &DecomposedQuery) -> bool {
    !dq.clean_artist.is_empty() && !is_unknown_artist(&dq.clean_artist)
}

/// High-confidence confirmation gate for provider-flagged instrumental tracks
/// (e.g., LRCLIB `instrumental: true`, NetEase `nolyric: true`, KuGou pure-music marker).
fn passes_instrumental_confirmation_gate(cand: &ScoredCandidate, dq: &DecomposedQuery) -> bool {
    if !cand.is_instrumental {
        return false;
    }

    let known_artist = has_known_artist(dq);
    let art_sim = if known_artist {
        artist_similarity(&cand.artist, &dq.clean_artist)
    } else {
        1.0
    };
    if known_artist && art_sim < 0.70 {
        return false;
    }

    let title_sim = best_title_similarity(&cand.title, &dq.title_variants);
    if is_short_title(&dq.clean_title) {
        if !has_exact_normalized_title_match(&cand.title, dq) {
            return false;
        }
        if known_artist && art_sim < 0.75 {
            return false;
        }
    } else if title_sim < 0.80 {
        return false;
    }

    if dq.duration_secs > 0.0 {
        if let Some(cd) = cand.duration_secs {
            if cd > 0 {
                let diff = (f64::from(cd) - dq.duration_secs).abs();
                if diff > 25.0 && !(title_sim >= 0.90 && (!known_artist || art_sim >= 0.85)) {
                    return false;
                }
            }
        }
    }

    true
}

/// Strict high-precision validation gate for ALL auto-fetched candidates.
/// Principle: Zero false positives > guessing a wrong song.
fn passes_auto_match_gates(cand: &ScoredCandidate, dq: &DecomposedQuery) -> bool {
    if cand.is_instrumental {
        return passes_instrumental_confirmation_gate(cand, dq);
    }

    let known_artist = has_known_artist(dq);
    let art_sim = if known_artist {
        artist_similarity(&cand.artist, &dq.clean_artist)
    } else {
        1.0
    };

    // Gate 1: Hard Artist Match Gate (synced LRC bonus can NEVER rescue a wrong artist)
    if known_artist && art_sim < 0.50 {
        return false;
    }

    // Gate 2: Hard Title Match Gate + Short-Title Protection
    let title_sim = best_title_similarity(&cand.title, &dq.title_variants);
    if is_short_title(&dq.clean_title) {
        if !has_exact_normalized_title_match(&cand.title, dq) {
            return false;
        }
        if known_artist && art_sim < 0.75 {
            return false;
        }
    } else {
        let exact_sub_with_strong_artist =
            known_artist && art_sim >= 0.85 && has_clean_substring_title_match(&cand.title, dq);
        if title_sim < 0.72 && !exact_sub_with_strong_artist {
            return false;
        }
    }

    // Gate 3: Duration Sanity Gate
    if dq.duration_secs > 0.0 {
        if let Some(cd) = cand.duration_secs {
            if cd > 0 {
                let diff = (f64::from(cd) - dq.duration_secs).abs();
                if diff > 25.0 && !(title_sim >= 0.90 && (!known_artist || art_sim >= 0.85)) {
                    return false;
                }
            }
        }
    }

    // Gate 4: Synced LRC / Plain Lyrics Quality & Timestamp Sanity Gate
    if cand.is_synced {
        let Some(lrc) = cand.synced_lrc.as_deref() else {
            return false;
        };
        if !is_usable_synced_lrc_for_duration(lrc, dq.duration_ms) {
            return false;
        }
    } else {
        let Some(plain) = cand.plain_lyrics.as_deref() else {
            return false;
        };
        if !is_usable_plain_lyrics(plain) {
            return false;
        }
    }

    true
}

#[cfg(test)]
fn score_candidate(
    cand_title: &str,
    cand_artist: &str,
    cand_dur_secs: Option<u32>,
    is_synced: bool,
    target_title: &str,
    target_artist: &str,
    target_dur_secs: f64,
) -> f64 {
    let title_sim = text_similarity(cand_title, target_title);
    score_candidate_with_sim(
        title_sim,
        cand_artist,
        cand_dur_secs,
        is_synced,
        target_artist,
        target_dur_secs,
    )
}

fn score_candidate_with_sim(
    title_sim: f64,
    cand_artist: &str,
    cand_dur_secs: Option<u32>,
    is_synced: bool,
    target_artist: &str,
    target_dur_secs: f64,
) -> f64 {
    let artist_score = if target_artist.is_empty() || is_unknown_artist(target_artist) {
        15.0
    } else {
        artist_similarity(cand_artist, target_artist) * 30.0
    };

    let dur_score = if target_dur_secs > 0.0 {
        if let Some(cd) = cand_dur_secs {
            if cd > 0 {
                let diff = (f64::from(cd) - target_dur_secs).abs();
                if diff <= 3.0 {
                    25.0
                } else if diff <= 5.0 {
                    20.0
                } else if diff <= 10.0 {
                    10.0
                } else if diff <= 15.0 {
                    0.0
                } else if diff <= 30.0 {
                    -((diff - 15.0) * 1.5)
                } else {
                    -((diff - 15.0) * 1.8).min(32.0)
                }
            } else {
                0.0
            }
        } else {
            0.0
        }
    } else {
        0.0
    };

    let synced_bonus = if is_synced { 18.0 } else { 0.0 };
    (title_sim * 50.0) + artist_score + dur_score + synced_bonus
}

fn is_usable_synced_lrc(lrc: &str) -> bool {
    is_usable_synced_lrc_for_duration(lrc, 0)
}

fn is_usable_synced_lrc_for_duration(lrc: &str, track_duration_ms: i64) -> bool {
    let trimmed = lrc.strip_prefix('\u{FEFF}').unwrap_or(lrc).trim();
    if trimmed.is_empty() || trimmed.len() > MAX_LRC_BYTES {
        return false;
    }
    if is_instrumental_placeholder(trimmed) {
        return false;
    }
    let lines = parse_lrc(trimmed);
    let meaningful: Vec<&LyricLine> = lines
        .iter()
        .filter(|l| {
            let t = l.text.trim();
            !t.is_empty() && t != "♪" && !is_credit_only_line(t)
        })
        .collect();
    if meaningful.len() < 3 {
        return false;
    }
    if track_duration_ms > 0 {
        if let Some(first) = meaningful.first() {
            if first.time_ms >= track_duration_ms {
                return false;
            }
        }
    }
    true
}

fn is_usable_plain_lyrics(text: &str) -> bool {
    let trimmed = text.strip_prefix('\u{FEFF}').unwrap_or(text).trim();
    if trimmed.is_empty() || trimmed.len() > MAX_LRC_BYTES {
        return false;
    }
    if is_instrumental_placeholder(trimmed) {
        return false;
    }
    let meaningful = trimmed
        .lines()
        .map(strip_lrc_timestamps)
        .map(str::trim)
        .filter(|l| !l.is_empty() && *l != "♪" && !is_credit_only_line(l))
        .count();
    meaningful >= 3
}

fn is_instrumental_placeholder(text: &str) -> bool {
    let lower = text.to_lowercase();
    let markers = [
        "纯音乐",
        "请欣赏",
        "敬请欣赏",
        "pure music",
        "no lyrics",
        "instrumental only",
        "this song is an instrumental",
        "[instrumental]",
        "(instrumental)",
        "instrumental track",
    ];
    if markers.iter().any(|m| lower.contains(m)) {
        let non_empty_lines = text
            .lines()
            .filter(|l| !strip_lrc_timestamps(l).trim().is_empty())
            .count();
        return non_empty_lines <= 5;
    }
    false
}

fn is_credit_only_line(line: &str) -> bool {
    let trimmed = line.trim();
    const CREDIT_PREFIXES: &[&str] = &[
        "作词",
        "作曲",
        "编曲",
        "制作人",
        "混音",
        "母带",
        "作詞",
        "編曲",
    ];
    CREDIT_PREFIXES.iter().any(|p| trimmed.starts_with(p))
}

fn strip_lrc_timestamps(line: &str) -> &str {
    let mut rest = line.trim();
    while rest.starts_with('[') {
        if let Some(end) = rest.find(']') {
            rest = rest[end + 1..].trim_start();
        } else {
            break;
        }
    }
    rest
}

fn build_lyrics_preview(synced: Option<&str>, plain: Option<&str>) -> String {
    let source_text = synced.or(plain).unwrap_or("");
    let mut picked = Vec::new();
    for raw in source_text.lines() {
        let clean = strip_lrc_timestamps(raw).trim();
        if clean.is_empty() || clean == "♪" || is_credit_only_line(clean) {
            continue;
        }
        picked.push(clean);
        if picked.len() >= 2 {
            break;
        }
    }
    let joined = picked.join(" / ");
    if joined.chars().count() > 140 {
        let truncated: String = joined.chars().take(137).collect();
        format!("{truncated}...")
    } else {
        joined
    }
}

// ============================================================================
// Stage 2: LRCLIB
// ============================================================================

fn extract_lrclib_candidate(
    item: LrclibResponse,
    dq: &DecomposedQuery,
) -> Option<ScoredCandidate> {
    let title = item
        .track_name
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| dq.clean_title.clone());
    let artist = item
        .artist_name
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| dq.clean_artist.clone());
    let dur = item
        .duration
        .filter(|d| *d > 0.0)
        .map(|d| d.round() as u32);
    let title_sim = best_title_similarity(&title, &dq.title_variants);

    if item.instrumental.unwrap_or(false) {
        let score = score_candidate_with_sim(
            title_sim,
            &artist,
            dur,
            false,
            &dq.clean_artist,
            dq.duration_secs,
        );
        return Some(ScoredCandidate {
            source: "lrclib".to_string(),
            title,
            artist,
            duration_secs: dur,
            synced_lrc: None,
            plain_lyrics: None,
            is_synced: false,
            is_instrumental: true,
            score,
        });
    }

    let synced = item.synced_lyrics.filter(|s| is_usable_synced_lrc(s));
    let plain = item
        .plain_lyrics
        .map(|s| s.trim().to_string())
        .filter(|s| is_usable_plain_lyrics(s));

    if synced.is_none() && plain.is_none() {
        return None;
    }

    let is_synced = synced.is_some();
    let score = score_candidate_with_sim(
        title_sim,
        &artist,
        dur,
        is_synced,
        &dq.clean_artist,
        dq.duration_secs,
    );

    Some(ScoredCandidate {
        source: "lrclib".to_string(),
        title,
        artist,
        duration_secs: dur,
        synced_lrc: synced,
        plain_lyrics: plain,
        is_synced,
        is_instrumental: false,
        score,
    })
}

fn fetch_lrclib_exact(
    client: &reqwest::blocking::Client,
    title: &str,
    artist: &str,
    album: &str,
    dq: &DecomposedQuery,
) -> Option<ScoredCandidate> {
    if is_provider_in_cooldown(ProviderId::Lrclib)
        || title.is_empty()
        || artist.is_empty()
        || dq.duration_secs <= 0.0
    {
        return None;
    }
    let url = if album.is_empty() {
        format!(
            "https://lrclib.net/api/get?track_name={}&artist_name={}&duration={}",
            urlencode(title),
            urlencode(artist),
            dq.duration_secs.round() as i64
        )
    } else {
        format!(
            "https://lrclib.net/api/get?track_name={}&artist_name={}&album_name={}&duration={}",
            urlencode(title),
            urlencode(artist),
            urlencode(album),
            dq.duration_secs.round() as i64
        )
    };

    let resp = client.get(&url).send().ok()?;
    note_http_status(ProviderId::Lrclib, resp.status());
    let data = read_bounded_json::<LrclibResponse>(resp)?;
    extract_lrclib_candidate(data, dq)
}

fn search_lrclib_candidates(
    client: &reqwest::blocking::Client,
    dq: &DecomposedQuery,
) -> Vec<ScoredCandidate> {
    if is_provider_in_cooldown(ProviderId::Lrclib) {
        return Vec::new();
    }

    let mut urls = Vec::new();
    if !dq.clean_title.is_empty() && !dq.clean_artist.is_empty() {
        urls.push(format!(
            "https://lrclib.net/api/search?track_name={}&artist_name={}",
            urlencode(&dq.clean_title),
            urlencode(&dq.clean_artist)
        ));
    }
    let combined = format!("{} {}", dq.clean_artist, dq.clean_title)
        .trim()
        .to_string();
    if !combined.is_empty() {
        urls.push(format!(
            "https://lrclib.net/api/search?q={}",
            urlencode(&combined)
        ));
    }

    let mut out = Vec::new();
    for url in urls {
        if is_provider_in_cooldown(ProviderId::Lrclib) {
            return out;
        }
        if let Ok(resp) = client.get(&url).send() {
            note_http_status(ProviderId::Lrclib, resp.status());
            if let Some(items) = read_bounded_json::<Vec<LrclibResponse>>(resp) {
                for item in items.into_iter().take(12) {
                    if let Some(cand) = extract_lrclib_candidate(item, dq) {
                        out.push(cand);
                    }
                }
            }
        }
        if out
            .iter()
            .any(|c| c.is_synced && c.score >= HIGH_CONFIDENCE_SYNCED_SCORE)
        {
            return out;
        }
    }

    // Fallback: title-only search + CJK/Romaji variants (critical when artist tag is a channel/wrong)
    for variant in dq.title_variants.iter().take(3) {
        if variant.is_empty() || is_provider_in_cooldown(ProviderId::Lrclib) {
            continue;
        }
        let q_url = format!("https://lrclib.net/api/search?q={}", urlencode(variant));
        if let Ok(resp) = client.get(&q_url).send() {
            note_http_status(ProviderId::Lrclib, resp.status());
            if let Some(items) = read_bounded_json::<Vec<LrclibResponse>>(resp) {
                for item in items.into_iter().take(10) {
                    if let Some(cand) = extract_lrclib_candidate(item, dq) {
                        out.push(cand);
                    }
                }
            }
        }
        if out
            .iter()
            .any(|c| c.is_synced && c.score >= HIGH_CONFIDENCE_SYNCED_SCORE)
        {
            break;
        }
    }

    out
}

// ============================================================================
// Stage 3: KuGou Music (Synced LRC)
// ============================================================================

fn search_kugou_candidates(
    client: &reqwest::blocking::Client,
    dq: &DecomposedQuery,
    max_downloads: usize,
) -> Vec<ScoredCandidate> {
    if is_provider_in_cooldown(ProviderId::Kugou) {
        return Vec::new();
    }

    let mut keywords = Vec::new();
    let primary = format!("{} {}", dq.clean_artist, dq.clean_title)
        .trim()
        .to_string();
    if !primary.is_empty() {
        keywords.push(primary);
    }
    for v in dq.title_variants.iter().skip(1).take(2) {
        let alt = format!("{} {v}", dq.clean_artist).trim().to_string();
        if !alt.is_empty() && !keywords.contains(&alt) {
            keywords.push(alt);
        }
    }

    let mut out = Vec::new();
    for keyword in keywords {
        if is_provider_in_cooldown(ProviderId::Kugou) {
            return out;
        }
        let url = if dq.duration_ms > 0 {
            format!(
                "https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword={}&duration={}",
                urlencode(&keyword),
                dq.duration_ms
            )
        } else {
            format!(
                "https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword={}",
                urlencode(&keyword)
            )
        };

        let Ok(resp) = client
            .get(&url)
            .header("User-Agent", BROWSER_USER_AGENT)
            .send()
        else {
            continue;
        };
        note_http_status(ProviderId::Kugou, resp.status());
        let Some(root) = read_bounded_json::<KugouSearchRoot>(resp) else {
            continue;
        };
        let list = root.candidates.unwrap_or_default();
        if list.is_empty() {
            continue;
        }

        let mut ranked: Vec<(f64, String, String, String, String, Option<u32>)> = list
            .into_iter()
            .filter_map(|c| {
                let id = c.id?.trim().to_string();
                let accesskey = c.accesskey?.trim().to_string();
                if id.is_empty() || accesskey.is_empty() {
                    return None;
                }
                let song = c
                    .song
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or_else(|| dq.clean_title.clone());
                let singer = c.singer.unwrap_or_default().trim().to_string();
                let dur_secs = c
                    .duration
                    .filter(|ms| *ms > 0)
                    .map(|ms| (ms / 1000) as u32);
                let sim = best_title_similarity(&song, &dq.title_variants);
                let meta_score = score_candidate_with_sim(
                    sim,
                    &singer,
                    dur_secs,
                    false,
                    &dq.clean_artist,
                    dq.duration_secs,
                );
                Some((meta_score, id, accesskey, song, singer, dur_secs))
            })
            .collect();

        ranked.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

        for (meta_score, id, accesskey, song, singer, dur_secs) in
            ranked.into_iter().take(max_downloads)
        {
            if meta_score < 12.0 || is_provider_in_cooldown(ProviderId::Kugou) {
                continue;
            }
            let dl_url = format!(
                "https://lyrics.kugou.com/download?ver=1&client=pc&id={}&accesskey={}&fmt=lrc&charset=utf8",
                urlencode(&id),
                urlencode(&accesskey)
            );
            let Ok(dl_resp) = client
                .get(&dl_url)
                .header("User-Agent", BROWSER_USER_AGENT)
                .send()
            else {
                continue;
            };
            note_http_status(ProviderId::Kugou, dl_resp.status());
            let Some(dl_root) = read_bounded_json::<KugouDownloadRoot>(dl_resp) else {
                continue;
            };
            let Some(b64) = dl_root.content else {
                continue;
            };
            let Some(decoded_bytes) = decode_base64(&b64) else {
                continue;
            };
            let Ok(raw_utf8) = String::from_utf8(decoded_bytes) else {
                continue;
            };
            let lrc = raw_utf8
                .strip_prefix('\u{FEFF}')
                .unwrap_or(&raw_utf8)
                .trim()
                .to_string();
            if lrc.is_empty() || lrc.len() > MAX_LRC_BYTES {
                continue;
            }
            if is_instrumental_placeholder(&lrc) {
                let sim = best_title_similarity(&song, &dq.title_variants);
                let score = score_candidate_with_sim(
                    sim,
                    &singer,
                    dur_secs,
                    false,
                    &dq.clean_artist,
                    dq.duration_secs,
                );
                out.push(ScoredCandidate {
                    source: "kugou".to_string(),
                    title: song,
                    artist: singer,
                    duration_secs: dur_secs,
                    synced_lrc: None,
                    plain_lyrics: None,
                    is_synced: false,
                    is_instrumental: true,
                    score,
                });
                continue;
            }
            let is_synced = is_usable_synced_lrc(&lrc);
            if !is_synced {
                continue;
            }
            let sim = best_title_similarity(&song, &dq.title_variants);
            let final_score = score_candidate_with_sim(
                sim,
                &singer,
                dur_secs,
                true,
                &dq.clean_artist,
                dq.duration_secs,
            );
            out.push(ScoredCandidate {
                source: "kugou".to_string(),
                title: song,
                artist: singer,
                duration_secs: dur_secs,
                synced_lrc: Some(lrc),
                plain_lyrics: None,
                is_synced: true,
                is_instrumental: false,
                score: final_score,
            });
        }

        if out
            .iter()
            .any(|c| c.is_synced && c.score >= HIGH_CONFIDENCE_SYNCED_SCORE)
        {
            break;
        }
    }

    out
}

// ============================================================================
// Stage 4: NetEase Cloud Music (POST Search + Synced LRC)
// ============================================================================

fn search_netease_candidates(
    client: &reqwest::blocking::Client,
    dq: &DecomposedQuery,
    max_lyric_fetches: usize,
) -> Vec<ScoredCandidate> {
    if is_provider_in_cooldown(ProviderId::Netease) {
        return Vec::new();
    }

    let mut queries = Vec::new();
    let primary = format!("{} {}", dq.clean_title, dq.clean_artist)
        .trim()
        .to_string();
    if !primary.is_empty() {
        queries.push(primary);
    }
    for v in dq.title_variants.iter().skip(1).take(2) {
        let alt = format!("{v} {}", dq.clean_artist).trim().to_string();
        if !alt.is_empty() && !queries.contains(&alt) {
            queries.push(alt);
        }
    }
    if queries.is_empty() {
        return Vec::new();
    }

    let mut out = Vec::new();
    let mut fetched_song_ids = HashSet::new();

    for query in queries {
        if is_provider_in_cooldown(ProviderId::Netease) {
            return out;
        }
        let form_body = format!("s={}&type=1&limit=8&offset=0", urlencode(&query));
        let resp = match client
            .post("https://music.163.com/api/search/get")
            .header("Referer", NETEASE_REFERER)
            .header("User-Agent", BROWSER_USER_AGENT)
            .header("Cookie", "os=pc")
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form_body)
            .send()
        {
            Ok(r) => r,
            Err(_) => continue,
        };
        note_http_status(ProviderId::Netease, resp.status());

        let Some(root) = read_bounded_json::<NeteaseSearchRoot>(resp) else {
            continue;
        };
        let songs = root.result.and_then(|r| r.songs).unwrap_or_default();
        if songs.is_empty() {
            continue;
        }

        let mut ranked_songs: Vec<(f64, i64, String, String, Option<u32>)> = songs
            .into_iter()
            .filter_map(|song| {
                let name = song.name?.trim().to_string();
                if name.is_empty() {
                    return None;
                }
                let artist_str = song
                    .artists
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|a| a.name)
                    .map(|n| n.trim().to_string())
                    .filter(|n| !n.is_empty())
                    .collect::<Vec<_>>()
                    .join(", ");
                let dur_secs = song
                    .duration
                    .filter(|ms| *ms > 0)
                    .map(|ms| (ms / 1000) as u32);
                let sim = best_title_similarity(&name, &dq.title_variants);
                let meta_score = score_candidate_with_sim(
                    sim,
                    &artist_str,
                    dur_secs,
                    false,
                    &dq.clean_artist,
                    dq.duration_secs,
                );
                Some((meta_score, song.id, name, artist_str, dur_secs))
            })
            .collect();

        ranked_songs.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

        for (meta_score, song_id, title, artist, dur_secs) in
            ranked_songs.into_iter().take(max_lyric_fetches)
        {
            if meta_score < 12.0
                || !fetched_song_ids.insert(song_id)
                || is_provider_in_cooldown(ProviderId::Netease)
            {
                continue;
            }
            let lyric_url = format!(
                "https://music.163.com/api/song/lyric?id={song_id}&lv=1&kv=1&tv=-1"
            );
            let Ok(lresp) = client
                .get(&lyric_url)
                .header("Referer", NETEASE_REFERER)
                .header("User-Agent", BROWSER_USER_AGENT)
                .header("Cookie", "os=pc")
                .send()
            else {
                continue;
            };
            note_http_status(ProviderId::Netease, lresp.status());
            let Some(lroot) = read_bounded_json::<NeteaseLyricRoot>(lresp) else {
                continue;
            };
            if lroot.nolyric.unwrap_or(false) {
                let sim = best_title_similarity(&title, &dq.title_variants);
                let score = score_candidate_with_sim(
                    sim,
                    &artist,
                    dur_secs,
                    false,
                    &dq.clean_artist,
                    dq.duration_secs,
                );
                out.push(ScoredCandidate {
                    source: "netease".to_string(),
                    title,
                    artist,
                    duration_secs: dur_secs,
                    synced_lrc: None,
                    plain_lyrics: None,
                    is_synced: false,
                    is_instrumental: true,
                    score,
                });
                continue;
            }
            let Some(raw_lrc) = lroot.lrc.and_then(|b| b.lyric) else {
                continue;
            };
            let trimmed = raw_lrc.strip_prefix('\u{FEFF}').unwrap_or(&raw_lrc).trim();
            if trimmed.is_empty() || trimmed.len() > MAX_LRC_BYTES {
                continue;
            }
            if is_instrumental_placeholder(trimmed) {
                let sim = best_title_similarity(&title, &dq.title_variants);
                let score = score_candidate_with_sim(
                    sim,
                    &artist,
                    dur_secs,
                    false,
                    &dq.clean_artist,
                    dq.duration_secs,
                );
                out.push(ScoredCandidate {
                    source: "netease".to_string(),
                    title,
                    artist,
                    duration_secs: dur_secs,
                    synced_lrc: None,
                    plain_lyrics: None,
                    is_synced: false,
                    is_instrumental: true,
                    score,
                });
                continue;
            }

            let is_synced = is_usable_synced_lrc(trimmed);
            let (synced_lrc, plain_lyrics) = if is_synced {
                (Some(trimmed.to_string()), None)
            } else {
                let stripped_plain: String = trimmed
                    .lines()
                    .map(strip_lrc_timestamps)
                    .map(str::trim)
                    .filter(|l| !l.is_empty() && !is_credit_only_line(l))
                    .collect::<Vec<_>>()
                    .join("\n");
                if stripped_plain.lines().count() < 2 {
                    continue;
                }
                (None, Some(stripped_plain))
            };

            let sim = best_title_similarity(&title, &dq.title_variants);
            let final_score = score_candidate_with_sim(
                sim,
                &artist,
                dur_secs,
                is_synced,
                &dq.clean_artist,
                dq.duration_secs,
            );
            out.push(ScoredCandidate {
                source: "netease".to_string(),
                title,
                artist,
                duration_secs: dur_secs,
                synced_lrc,
                plain_lyrics,
                is_synced,
                is_instrumental: false,
                score: final_score,
            });
        }

        if out
            .iter()
            .any(|c| c.is_synced && c.score >= HIGH_CONFIDENCE_SYNCED_SCORE)
        {
            break;
        }
    }

    out
}

// ============================================================================
// Stage 5: Musixmatch Public Desktop API (Cached Token + Synced/Plain)
// ============================================================================

fn get_musixmatch_token(client: &reqwest::blocking::Client, force_refresh: bool) -> Option<String> {
    if is_provider_in_cooldown(ProviderId::Musixmatch) {
        return None;
    }
    let lock = MUSIXMATCH_TOKEN_CACHE.get_or_init(|| Mutex::new(None));
    if !force_refresh {
        if let Ok(guard) = lock.lock() {
            if let Some((tok, fetched_at)) = guard.as_ref() {
                if fetched_at.elapsed() < Duration::from_secs(MUSIXMATCH_TOKEN_TTL_SECS) {
                    return Some(tok.clone());
                }
            }
        }
    }

    let url = format!(
        "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id={MUSIXMATCH_APP_ID}"
    );
    let resp = client
        .get(&url)
        .header("User-Agent", BROWSER_USER_AGENT)
        .header("Cookie", "AWSELB=unknown")
        .send()
        .ok()?;
    note_http_status(ProviderId::Musixmatch, resp.status());
    let json: serde_json::Value = read_bounded_json(resp)?;
    let status = json.pointer("/message/header/status_code")?.as_i64()?;
    if status == 429 {
        note_http_status(
            ProviderId::Musixmatch,
            reqwest::StatusCode::TOO_MANY_REQUESTS,
        );
        return None;
    }
    if status != 200 {
        return None;
    }
    let token = json
        .pointer("/message/body/user_token")?
        .as_str()?
        .trim()
        .to_string();
    if token.is_empty() || token.eq_ignore_ascii_case("UpgradeOnlyUpgradeOnlyUpgradeOnlyUpgradeOnly") {
        return None;
    }

    if let Ok(mut guard) = lock.lock() {
        *guard = Some((token.clone(), Instant::now()));
    }
    Some(token)
}

fn invalidate_musixmatch_token() {
    if let Some(lock) = MUSIXMATCH_TOKEN_CACHE.get() {
        if let Ok(mut guard) = lock.lock() {
            *guard = None;
        }
    }
}

fn query_musixmatch_endpoint(
    client: &reqwest::blocking::Client,
    endpoint: &str,
    token: &str,
    dq: &DecomposedQuery,
) -> Option<(i64, serde_json::Value)> {
    if is_provider_in_cooldown(ProviderId::Musixmatch) {
        return None;
    }
    let mut url = format!(
        "https://apic-desktop.musixmatch.com/ws/1.1/{endpoint}?app_id={MUSIXMATCH_APP_ID}&usertoken={}&q_track={}",
        urlencode(token),
        urlencode(&dq.clean_title)
    );
    if !dq.clean_artist.is_empty() {
        url.push_str(&format!("&q_artist={}", urlencode(&dq.clean_artist)));
    }
    if endpoint == "matcher.subtitle.get" {
        url.push_str("&subtitle_format=lrc");
        if dq.duration_secs > 0.0 {
            url.push_str(&format!(
                "&f_subtitle_length={}&f_subtitle_length_max_deviation=5",
                dq.duration_secs.round() as i64
            ));
        }
    }

    let resp = client
        .get(&url)
        .header("User-Agent", BROWSER_USER_AGENT)
        .header("Cookie", "AWSELB=unknown")
        .send()
        .ok()?;
    note_http_status(ProviderId::Musixmatch, resp.status());
    let json: serde_json::Value = read_bounded_json(resp)?;
    let status = json
        .pointer("/message/header/status_code")
        .and_then(serde_json::Value::as_i64)
        .unwrap_or(0);
    if status == 429 {
        note_http_status(
            ProviderId::Musixmatch,
            reqwest::StatusCode::TOO_MANY_REQUESTS,
        );
    }
    Some((status, json))
}

fn fetch_musixmatch_candidate(
    client: &reqwest::blocking::Client,
    dq: &DecomposedQuery,
) -> Option<ScoredCandidate> {
    if dq.clean_title.is_empty() || is_provider_in_cooldown(ProviderId::Musixmatch) {
        return None;
    }

    for attempt in 0..2 {
        let token = get_musixmatch_token(client, attempt > 0)?;

        // 1. Try synced LRC subtitle
        if let Some((status, json)) =
            query_musixmatch_endpoint(client, "matcher.subtitle.get", &token, dq)
        {
            if status == 401 {
                invalidate_musixmatch_token();
                continue;
            }
            if status == 200 {
                if let Some(body) = json
                    .pointer("/message/body/subtitle/subtitle_body")
                    .and_then(serde_json::Value::as_str)
                {
                    let trimmed = body.trim();
                    if is_usable_synced_lrc(trimmed) {
                        let dur = json
                            .pointer("/message/body/subtitle/subtitle_length")
                            .and_then(serde_json::Value::as_u64)
                            .map(|d| d as u32);
                        let score = score_candidate_with_sim(
                            0.92,
                            &dq.clean_artist,
                            dur,
                            true,
                            &dq.clean_artist,
                            dq.duration_secs,
                        );
                        return Some(ScoredCandidate {
                            source: "musixmatch".to_string(),
                            title: dq.clean_title.clone(),
                            artist: dq.clean_artist.clone(),
                            duration_secs: dur,
                            synced_lrc: Some(trimmed.to_string()),
                            plain_lyrics: None,
                            is_synced: true,
                            is_instrumental: false,
                            score,
                        });
                    }
                }
            }
        }

        // 2. Fallback to plain lyrics
        if let Some((status, json)) =
            query_musixmatch_endpoint(client, "matcher.lyrics.get", &token, dq)
        {
            if status == 401 {
                invalidate_musixmatch_token();
                continue;
            }
            if status == 200 {
                if let Some(body) = json
                    .pointer("/message/body/lyrics/lyrics_body")
                    .and_then(serde_json::Value::as_str)
                {
                    let cleaned: String = body
                        .lines()
                        .take_while(|line| !line.contains("******* This Lyrics is NOT"))
                        .collect::<Vec<_>>()
                        .join("\n")
                        .trim()
                        .to_string();
                    if !cleaned.is_empty() && cleaned.len() <= MAX_LRC_BYTES {
                        return Some(ScoredCandidate {
                            source: "musixmatch".to_string(),
                            title: dq.clean_title.clone(),
                            artist: dq.clean_artist.clone(),
                            duration_secs: None,
                            synced_lrc: None,
                            plain_lyrics: Some(cleaned),
                            is_synced: false,
                            is_instrumental: false,
                            score: 62.0,
                        });
                    }
                }
            }
        }
        break;
    }

    None
}

// ============================================================================
// Stage 6: Plain-Text Fallbacks (Lyrics.ovh + Genius Public Search)
// ============================================================================

fn fetch_lyrics_ovh(
    client: &reqwest::blocking::Client,
    dq: &DecomposedQuery,
) -> Option<ScoredCandidate> {
    if is_provider_in_cooldown(ProviderId::LyricsOvh)
        || dq.clean_artist.is_empty()
        || is_unknown_artist(&dq.clean_artist)
        || dq.clean_title.is_empty()
    {
        return None;
    }
    let url = format!(
        "https://api.lyrics.ovh/v1/{}/{}",
        urlencode(&dq.clean_artist),
        urlencode(&dq.clean_title)
    );
    let resp = client.get(&url).send().ok()?;
    note_http_status(ProviderId::LyricsOvh, resp.status());
    let data = read_bounded_json::<LyricsOvhResponse>(resp)?;
    let plain = data
        .lyrics
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.len() <= MAX_LRC_BYTES)?;

    Some(ScoredCandidate {
        source: "lyrics_ovh".to_string(),
        title: dq.clean_title.clone(),
        artist: dq.clean_artist.clone(),
        duration_secs: None,
        synced_lrc: None,
        plain_lyrics: Some(plain),
        is_synced: false,
        is_instrumental: false,
        score: 42.0,
    })
}

fn decode_html_entities(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut rest = input;
    while let Some(amp_idx) = rest.find('&') {
        out.push_str(&rest[..amp_idx]);
        let after = &rest[amp_idx + 1..];
        if let Some(semi_idx) = after.find(';') {
            if semi_idx <= 10 {
                let entity = &after[..semi_idx];
                let decoded = match entity {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    "nbsp" => Some(' '),
                    s if s.starts_with("#x") || s.starts_with("#X") => {
                        u32::from_str_radix(&s[2..], 16).ok().and_then(char::from_u32)
                    }
                    s if s.starts_with('#') => s[1..].parse::<u32>().ok().and_then(char::from_u32),
                    _ => None,
                };
                if let Some(ch) = decoded {
                    out.push(ch);
                    rest = &after[semi_idx + 1..];
                    continue;
                }
            }
        }
        out.push('&');
        rest = after;
    }
    out.push_str(rest);
    out
}

/// Extracts plain lyrics text from Genius HTML `data-lyrics-container="true"` blocks.
fn extract_genius_lyrics_from_html(html: &str) -> Option<String> {
    const MARKER: &str = "data-lyrics-container=\"true\"";
    let mut sections = Vec::new();
    let mut search_from = 0usize;

    while let Some(rel_idx) = html[search_from..].find(MARKER) {
        let abs_idx = search_from + rel_idx;
        let Some(open_end_rel) = html[abs_idx..].find('>') else {
            break;
        };
        let content_start = abs_idx + open_end_rel + 1;
        let mut cursor = content_start;
        let mut depth: i32 = 1;

        while cursor < html.len() && depth > 0 {
            let remaining = &html[cursor..];
            let next_lt = remaining.find('<');
            let Some(lt_rel) = next_lt else {
                break;
            };
            let tag_start = cursor + lt_rel;
            let Some(gt_rel) = html[tag_start..].find('>') else {
                break;
            };
            let tag_end = tag_start + gt_rel + 1;
            let tag_inner = html[tag_start + 1..tag_end - 1].trim();
            let lower_tag = tag_inner.to_ascii_lowercase();

            if lower_tag.starts_with("div") && !lower_tag.ends_with('/') {
                depth += 1;
            } else if lower_tag.starts_with("/div") {
                depth -= 1;
                if depth == 0 {
                    let block = &html[content_start..tag_start];
                    sections.push(strip_html_block_to_lyrics(block));
                    search_from = tag_end;
                    break;
                }
            }
            cursor = tag_end;
        }
        if depth != 0 {
            break;
        }
    }

    let joined = sections
        .into_iter()
        .filter(|s| !s.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");

    let cleaned = joined.trim().to_string();
    if cleaned.lines().count() >= 3 && cleaned.len() <= MAX_LRC_BYTES {
        Some(cleaned)
    } else {
        None
    }
}

fn strip_html_block_to_lyrics(block: &str) -> String {
    let mut out = String::with_capacity(block.len());
    let mut cursor = 0usize;
    while cursor < block.len() {
        let remaining = &block[cursor..];
        let Some(lt_rel) = remaining.find('<') else {
            out.push_str(remaining);
            break;
        };
        out.push_str(&remaining[..lt_rel]);
        let tag_start = cursor + lt_rel;
        let Some(gt_rel) = block[tag_start..].find('>') else {
            break;
        };
        let tag_inner = block[tag_start + 1..tag_start + gt_rel].trim();
        let lower = tag_inner.to_ascii_lowercase();
        if lower.starts_with("br") || lower.starts_with("/p") || lower.starts_with("/div") {
            out.push('\n');
        }
        cursor = tag_start + gt_rel + 1;
    }

    let decoded = decode_html_entities(&out);
    let mut lines = Vec::new();
    let mut blank_run = 0;
    for line in decoded.lines() {
        let t = line.trim();
        if t.is_empty() {
            blank_run += 1;
            if blank_run <= 1 && !lines.is_empty() {
                lines.push("");
            }
        } else {
            blank_run = 0;
            lines.push(t);
        }
    }
    lines.join("\n").trim().to_string()
}

/// Strictly parses and validates that a Genius lyric URL is HTTPS on `genius.com` (CWE-918).
fn validate_genius_url(raw: &str) -> Option<reqwest::Url> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 1024 {
        return None;
    }
    if trimmed.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return None;
    }
    let parsed = reqwest::Url::parse(trimmed).ok()?;
    if parsed.scheme() != "https" {
        return None;
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return None;
    }
    let host = parsed.host_str()?.to_ascii_lowercase();
    if host != "genius.com" {
        return None;
    }
    Some(parsed)
}

fn fetch_genius_lyrics(
    client: &reqwest::blocking::Client,
    dq: &DecomposedQuery,
) -> Option<ScoredCandidate> {
    if is_provider_in_cooldown(ProviderId::Genius) {
        return None;
    }
    let query = format!("{} {}", dq.clean_artist, dq.clean_title)
        .trim()
        .to_string();
    if query.is_empty() {
        return None;
    }

    let search_url = format!(
        "https://genius.com/api/search/song?q={}&per_page=5",
        urlencode(&query)
    );
    let resp = client
        .get(&search_url)
        .header("User-Agent", BROWSER_USER_AGENT)
        .send()
        .ok()?;
    note_http_status(ProviderId::Genius, resp.status());
    let json: serde_json::Value = read_bounded_json(resp)?;

    let sections = json.pointer("/response/sections")?.as_array()?;
    let mut best_hit: Option<(f64, String, String, reqwest::Url)> = None;

    for section in sections {
        let Some(hits) = section.get("hits").and_then(serde_json::Value::as_array) else {
            continue;
        };
        for hit in hits {
            let Some(res) = hit.get("result") else {
                continue;
            };
            let Some(url_str) = res.get("url").and_then(serde_json::Value::as_str) else {
                continue;
            };
            // Strict RFC-3986 SSRF host allowlist
            let Some(safe_url) = validate_genius_url(url_str) else {
                continue;
            };
            let title = res
                .get("title")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .trim();
            let artist = res
                .get("artist_names")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .trim();
            let sim = best_title_similarity(title, &dq.title_variants);
            let score = score_candidate_with_sim(
                sim,
                artist,
                None,
                false,
                &dq.clean_artist,
                0.0,
            );
            if score >= 35.0
                && best_hit
                    .as_ref()
                    .is_none_or(|(best_s, _, _, _)| score > *best_s)
            {
                best_hit = Some((score, title.to_string(), artist.to_string(), safe_url));
            }
        }
    }

    let (score, title, artist, page_url) = best_hit?;
    if is_provider_in_cooldown(ProviderId::Genius) {
        return None;
    }
    let page_resp = client
        .get(page_url)
        .header("User-Agent", BROWSER_USER_AGENT)
        .send()
        .ok()?;
    note_http_status(ProviderId::Genius, page_resp.status());
    let bytes = read_bounded_bytes(page_resp)?;
    let html = String::from_utf8_lossy(&bytes);
    let plain = extract_genius_lyrics_from_html(&html)?;

    Some(ScoredCandidate {
        source: "genius".to_string(),
        title,
        artist,
        duration_secs: None,
        synced_lrc: None,
        plain_lyrics: Some(plain),
        is_synced: false,
        is_instrumental: false,
        score,
    })
}

// ============================================================================
// Master 6-Provider Parallel Synced-First Cascade Orchestrator
// ============================================================================

fn record_candidate(
    candidate: ScoredCandidate,
    dq: &DecomposedQuery,
    best_synced: &mut Option<ScoredCandidate>,
    best_instrumental: &mut Option<ScoredCandidate>,
    best_plain_fallback: &mut Option<ScoredCandidate>,
) {
    if !passes_auto_match_gates(&candidate, dq) {
        return;
    }
    if candidate.is_synced && candidate.synced_lrc.is_some() {
        if best_synced
            .as_ref()
            .is_none_or(|cur| candidate.score > cur.score)
        {
            *best_synced = Some(candidate);
        }
    } else if candidate.is_instrumental {
        if best_instrumental
            .as_ref()
            .is_none_or(|cur| candidate.score > cur.score)
        {
            *best_instrumental = Some(candidate);
        }
    } else if candidate.plain_lyrics.is_some()
        && best_plain_fallback
            .as_ref()
            .is_none_or(|cur| candidate.score > cur.score)
    {
        *best_plain_fallback = Some(candidate);
    }
}

/// Strictly prioritizes any qualifying synced LRC candidate over plain-text fallbacks,
/// and surfaces provider-confirmed instrumental tracks when no verified lyrics exist.
fn select_best_synced_first(
    best_synced: Option<ScoredCandidate>,
    best_instrumental: Option<ScoredCandidate>,
    best_plain_fallback: Option<ScoredCandidate>,
) -> Option<ScoredCandidate> {
    if let Some(synced) = best_synced {
        if synced.score >= MIN_AUTO_MATCH_SCORE {
            return Some(synced);
        }
    }
    if let Some(plain) = best_plain_fallback {
        if plain.score >= MIN_AUTO_MATCH_SCORE {
            return Some(plain);
        }
    }
    if let Some(inst) = best_instrumental {
        return Some(inst);
    }
    None
}

fn fetch_six_provider_lyrics(track: &Track) -> Result<Option<ScoredCandidate>, String> {
    let client = shared_http_client()?;
    let dq = decompose_query_parts(
        &track.title,
        track.artist.as_deref().unwrap_or(""),
        track.album.as_deref().unwrap_or(""),
        &track.path,
        track.duration_ms.unwrap_or(0),
    );

    if dq.clean_title.is_empty() {
        return Ok(None);
    }

    let mut best_synced: Option<ScoredCandidate> = None;
    let mut best_instrumental: Option<ScoredCandidate> = None;
    let mut best_plain_fallback: Option<ScoredCandidate> = None;

    // Stage 1 (~200ms fast path): LRCLIB exact /api/get lookup.
    // Returns immediately ONLY on verified synced LRC or confirmed instrumental:true.
    // Never short-circuits on plain-only matches so Stage 2 can still find synced LRC.
    if let Some(exact) = fetch_lrclib_exact(client, &dq.raw_title, &dq.raw_artist, &dq.album, &dq) {
        if (exact.is_synced || exact.is_instrumental) && passes_auto_match_gates(&exact, &dq) {
            return Ok(Some(exact));
        }
        record_candidate(
            exact,
            &dq,
            &mut best_synced,
            &mut best_instrumental,
            &mut best_plain_fallback,
        );
    }
    if dq.clean_title != dq.raw_title || dq.clean_artist != dq.raw_artist {
        if let Some(exact) = fetch_lrclib_exact(client, &dq.clean_title, &dq.clean_artist, "", &dq)
        {
            if (exact.is_synced || exact.is_instrumental) && passes_auto_match_gates(&exact, &dq) {
                return Ok(Some(exact));
            }
            record_candidate(
                exact,
                &dq,
                &mut best_synced,
                &mut best_instrumental,
                &mut best_plain_fallback,
            );
        }
    }

    // Stage 2 (~0.8-1.5s parallel race): Query LRCLIB Search, KuGou, NetEase, and Musixmatch
    // CONCURRENTLY via std::thread::scope so worst-case latency is max(provider) instead of sum.
    let (lrclib_list, kugou_list, netease_list, mxm_opt) = std::thread::scope(|s| {
        let t_lrc = s.spawn(|| search_lrclib_candidates(client, &dq));
        let t_kg = s.spawn(|| search_kugou_candidates(client, &dq, 2));
        let t_ne = s.spawn(|| search_netease_candidates(client, &dq, 3));
        let t_mxm = s.spawn(|| fetch_musixmatch_candidate(client, &dq));

        (
            t_lrc.join().unwrap_or_default(),
            t_kg.join().unwrap_or_default(),
            t_ne.join().unwrap_or_default(),
            t_mxm.join().unwrap_or(None),
        )
    });

    for cand in lrclib_list
        .into_iter()
        .chain(kugou_list)
        .chain(netease_list)
        .chain(mxm_opt)
    {
        record_candidate(
            cand,
            &dq,
            &mut best_synced,
            &mut best_instrumental,
            &mut best_plain_fallback,
        );
    }

    // Synced ALWAYS beats plain; confirmed instrumental prevents falling through to plain scrapers.
    if let Some(chosen) =
        select_best_synced_first(best_synced, best_instrumental, best_plain_fallback)
    {
        return Ok(Some(chosen));
    }

    // Stage 3 (parallel plain fallback, 3.5s timeout): Only runs if Stage 2 produced nothing.
    let fallback_client = shared_plain_fallback_client()?;
    let (ovh_opt, genius_opt) = std::thread::scope(|s| {
        let t_ovh = s.spawn(|| fetch_lyrics_ovh(fallback_client, &dq));
        let t_gen = s.spawn(|| fetch_genius_lyrics(fallback_client, &dq));
        (t_ovh.join().unwrap_or(None), t_gen.join().unwrap_or(None))
    });

    let mut stage3_synced: Option<ScoredCandidate> = None;
    let mut stage3_inst: Option<ScoredCandidate> = None;
    let mut stage3_plain: Option<ScoredCandidate> = None;
    for cand in ovh_opt.into_iter().chain(genius_opt) {
        record_candidate(
            cand,
            &dq,
            &mut stage3_synced,
            &mut stage3_inst,
            &mut stage3_plain,
        );
    }

    Ok(select_best_synced_first(
        stage3_synced,
        stage3_inst,
        stage3_plain,
    ))
}

pub fn get_lyrics_coverage(db_path: String) -> Result<LyricsCoverageStats, String> {
    let conn = get_connection(&db_path)?;
    let total_tracks: u32 = conn
        .query_row("SELECT COUNT(*) FROM tracks WHERE unreadable = 0", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;

    let synced_count: u32 = conn
        .query_row(
            "SELECT COUNT(*) FROM lyrics WHERE status = 'found' AND synced_lrc IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    let plain_count: u32 = conn
        .query_row(
            "SELECT COUNT(*) FROM lyrics WHERE status = 'found' AND synced_lrc IS NULL AND plain IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    let instrumental_count: u32 = conn
        .query_row(
            "SELECT COUNT(*) FROM lyrics WHERE status = 'instrumental'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    let not_found_count: u32 = conn
        .query_row(
            "SELECT COUNT(*) FROM lyrics WHERE status = 'not_found'",
            [],
            |r| r.get(0),
        )
        .unwrap_or(0);

    Ok(LyricsCoverageStats {
        total_tracks,
        synced_count,
        plain_count,
        instrumental_count,
        not_found_count,
    })
}

pub fn bulk_download_lyrics(
    db_path: String,
    sink: StreamSink<String>,
) -> Result<(), String> {
    CANCEL_BULK_DOWNLOAD.store(false, Ordering::SeqCst);

    // Selects all tracks without synced lyrics and not already confirmed instrumental
    // (retrying 'not_found' AND upgrading previously cached plain-only tracks to synced LRC).
    let tracks: Vec<Track> = {
        let conn = get_connection(&db_path)?;
        let sql = format!(
            "{} WHERE t.unreadable = 0 AND t.id NOT IN (SELECT track_id FROM lyrics WHERE (status = 'found' AND synced_lrc IS NOT NULL) OR status = 'instrumental')",
            crate::api::library::TRACK_SELECT
        );
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], crate::api::library::map_track)
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?
    };
    let total = tracks.len() as u32;

    if total == 0 {
        let final_progress = BulkDownloadProgress {
            total: 0,
            processed: 0,
            success_synced: 0,
            success_plain: 0,
            instrumental_count: 0,
            not_found: 0,
            finished: true,
        };
        if let Ok(json) = serde_json::to_string(&final_progress) {
            let _ = sink.add(json);
        }
        return Ok(());
    }

    let queue = Mutex::new(VecDeque::from(tracks));
    let processed = AtomicU32::new(0);
    let success_synced = AtomicU32::new(0);
    let success_plain = AtomicU32::new(0);
    let instrumental_count = AtomicU32::new(0);
    let not_found = AtomicU32::new(0);
    let sink_lock = Mutex::new(());

    let worker_count = BULK_WORKER_COUNT.min(total as usize).max(1);

    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let queue_ref = &queue;
            let processed_ref = &processed;
            let synced_ref = &success_synced;
            let plain_ref = &success_plain;
            let inst_ref = &instrumental_count;
            let nf_ref = &not_found;
            let sink_lock_ref = &sink_lock;
            let sink_ref = &sink;
            let db_path_ref = &db_path;

            scope.spawn(move || loop {
                if CANCEL_BULK_DOWNLOAD.load(Ordering::SeqCst) {
                    break;
                }
                let next_track = {
                    let Ok(mut guard) = queue_ref.lock() else {
                        break;
                    };
                    guard.pop_front()
                };
                let Some(track) = next_track else {
                    break;
                };

                // force_refresh=true lets plain-only cached tracks upgrade to synced LRC while
                // safely preserving existing plain lyrics if no synced match is found.
                match get_lyrics(db_path_ref.clone(), track.id, true, true) {
                    Ok(Some(r)) if r.is_synced => {
                        synced_ref.fetch_add(1, Ordering::Relaxed);
                    }
                    Ok(Some(r)) if r.is_instrumental => {
                        inst_ref.fetch_add(1, Ordering::Relaxed);
                    }
                    Ok(Some(_)) => {
                        plain_ref.fetch_add(1, Ordering::Relaxed);
                    }
                    _ => {
                        nf_ref.fetch_add(1, Ordering::Relaxed);
                    }
                }

                // Serialize progress snapshots so emitted counts are strictly monotonic.
                if let Ok(_guard) = sink_lock_ref.lock() {
                    let cur_processed = processed_ref.fetch_add(1, Ordering::SeqCst) + 1;
                    let progress = BulkDownloadProgress {
                        total,
                        processed: cur_processed,
                        success_synced: synced_ref.load(Ordering::Relaxed),
                        success_plain: plain_ref.load(Ordering::Relaxed),
                        instrumental_count: inst_ref.load(Ordering::Relaxed),
                        not_found: nf_ref.load(Ordering::Relaxed),
                        finished: false,
                    };
                    if let Ok(json) = serde_json::to_string(&progress) {
                        let _ = sink_ref.add(json);
                    }
                }
            });
        }
    });

    let final_progress = BulkDownloadProgress {
        total,
        processed: processed.load(Ordering::SeqCst),
        success_synced: success_synced.load(Ordering::Relaxed),
        success_plain: success_plain.load(Ordering::Relaxed),
        instrumental_count: instrumental_count.load(Ordering::Relaxed),
        not_found: not_found.load(Ordering::Relaxed),
        finished: true,
    };
    if let Ok(json) = serde_json::to_string(&final_progress) {
        let _ = sink.add(json);
    }

    Ok(())
}

pub fn clear_all_lyrics(db_path: String) -> Result<(), String> {
    let conn = get_connection(&db_path)?;
    conn.execute("DELETE FROM lyrics", [])
        .map_err(|e| e.to_string())?;
    Ok(())
}

/// Deletes auto-fetched cached lyrics (including `not_found` entries) while
/// preserving user-saved custom/manual lyrics. Returns the count cleared.
pub fn clear_auto_lyrics_cache(db_path: String) -> Result<u32, String> {
    let conn = get_connection(&db_path)?;
    let deleted = conn
        .execute(
            "DELETE FROM lyrics
             WHERE LOWER(source) NOT IN ('custom', 'manual')
               AND LOWER(source) NOT LIKE 'custom:%'
               AND LOWER(source) NOT LIKE 'manual:%'",
            [],
        )
        .map_err(|e| e.to_string())?;
    Ok(deleted as u32)
}

fn urlencode(s: &str) -> String {
    let mut res = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' || b == b'~' {
            res.push(b as char);
        } else {
            res.push_str(&format!("%{b:02X}"));
        }
    }
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_lrc_timestamps_and_sorting() {
        let lrc = "[00:10.50]Second line\n[00:02.10]First line\n[01:00.00]Third line";
        let parsed = parse_lrc(lrc);
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].time_ms, 2100);
        assert_eq!(parsed[0].text, "First line");
        assert_eq!(parsed[1].time_ms, 10500);
        assert_eq!(parsed[1].text, "Second line");
        assert_eq!(parsed[2].time_ms, 60000);
        assert_eq!(parsed[2].text, "Third line");
    }

    #[test]
    fn test_parse_lrc_multi_timestamp_and_instrumental() {
        let lrc = "[00:01.0]First\n[00:05.00]\n[00:10.000]Third";
        let parsed = parse_lrc(lrc);
        assert_eq!(parsed.len(), 3);
        assert_eq!(parsed[0].time_ms, 1000);
        assert_eq!(parsed[0].text, "First");
        assert_eq!(parsed[1].time_ms, 5000);
        assert_eq!(parsed[1].text, "♪");
        assert_eq!(parsed[2].time_ms, 10000);
        assert_eq!(parsed[2].text, "Third");
    }

    #[test]
    fn test_parse_lrc_offset_tag_and_malformed_utf8_no_panic() {
        let lrc = "[offset:500]\n[offset:]\n[OFFSET:İ]\n[999999999999999999:99]bad\n[00:02.00]First line";
        let parsed = parse_lrc(lrc);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].time_ms, 2500);
    }

    #[test]
    fn test_clean_for_lyrics_query_comprehensive() {
        assert_eq!(
            clean_for_lyrics_query("Song Title (Official Video) [HD]"),
            "Song Title"
        );
        assert_eq!(
            clean_for_lyrics_query("Track Name feat. Artist B"),
            "Track Name"
        );
        assert_eq!(
            clean_for_lyrics_query("3分29秒 [Lyric Video]"),
            "3分29秒"
        );
        assert_eq!(
            clean_for_lyrics_query("Çağrı (Remastered 2024)"),
            "Çağrı"
        );
        assert_eq!(
            clean_for_lyrics_query("01 - アイドル（TV Size）.flac"),
            "アイドル"
        );
        assert_eq!(
            clean_for_lyrics_query("[07] Gurenge 【Full Ver.】 (Official MV).mp3"),
            "Gurenge"
        );
        assert_eq!(clean_for_lyrics_query("1979 (Remastered 2012)"), "1979");
    }

    #[test]
    fn test_split_artist_title_and_clean_artist_suffixes() {
        assert_eq!(clean_artist_channel_suffixes("Aimer - Topic"), "Aimer");
        assert_eq!(clean_artist_channel_suffixes("TarkanVEVO"), "Tarkan");
        assert_eq!(
            clean_artist_channel_suffixes("Mabel Matiz Official Channel"),
            "Mabel Matiz"
        );

        let dq1 = decompose_query_parts(
            "01 - Duman – Senden Daha Güzel (Official Video)",
            "<unknown>",
            "",
            "",
            245_000,
        );
        assert_eq!(dq1.clean_artist, "Duman");
        assert_eq!(dq1.clean_title, "Senden Daha Güzel");

        let dq2 = decompose_query_parts(
            "Unknown",
            "Various Artists",
            "",
            "/music/[04] Sezen Aksu | Gülümse.flac",
            280_000,
        );
        assert_eq!(dq2.clean_artist, "Sezen Aksu");
        assert_eq!(dq2.clean_title, "Gülümse");
    }

    #[test]
    fn test_extract_cjk_romaji_variants() {
        let v1 = extract_cjk_latin_variants("残響散歌 (Zankyosanka)");
        assert!(v1.contains(&"残響散歌".to_string()));
        assert!(v1.contains(&"Zankyosanka".to_string()));

        let v2 = extract_cjk_latin_variants("Gurenge / 紅蓮華");
        assert!(v2.contains(&"紅蓮華".to_string()));
        assert!(v2.contains(&"Gurenge".to_string()));
    }

    #[test]
    fn test_decode_base64_and_kugou_lrc_bom() {
        // UTF-8 BOM + "[00:01.00]Hello\n[00:05.00]World"
        let b64 = "77u/WzAwOjAxLjAwXUhlbGxvClswMDowNS4wMF1Xb3JsZA==";
        let bytes = decode_base64(b64).expect("valid base64");
        let text = String::from_utf8(bytes).expect("valid utf8");
        assert!(text.starts_with('\u{FEFF}'));
        let parsed = parse_lrc(&text);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].text, "Hello");
        assert_eq!(parsed[1].time_ms, 5000);
        assert_eq!(parsed[1].text, "World");
        assert!(decode_base64("!!!invalid!!!").is_none());
    }

    #[test]
    fn test_extract_genius_lyrics_containers() {
        let html = r#"
            <html><body>
            <div data-lyrics-container="true">Line one &amp; two<br/>Line three&#x27;s test<br>Line four</div>
            <div data-lyrics-container="true"><span>Chorus &quot;hey&quot;</span><br/>End line</div>
            </body></html>
        "#;
        let extracted = extract_genius_lyrics_from_html(html).expect("extracted genius lyrics");
        assert!(extracted.contains("Line one & two"));
        assert!(extracted.contains("Line three's test"));
        assert!(extracted.contains("Chorus \"hey\""));
    }

    #[test]
    fn test_candidate_scoring_prefers_duration_and_synced() {
        let synced_exact = score_candidate(
            "アイドル",
            "YOASOBI",
            Some(213),
            true,
            "アイドル",
            "YOASOBI",
            214.0,
        );
        let plain_exact = score_candidate(
            "アイドル",
            "YOASOBI",
            Some(213),
            false,
            "アイドル",
            "YOASOBI",
            214.0,
        );
        let wrong_dur = score_candidate(
            "アイドル",
            "YOASOBI",
            Some(90),
            true,
            "アイドル",
            "YOASOBI",
            214.0,
        );
        assert!(synced_exact > plain_exact);
        assert!(synced_exact > wrong_dur);
        assert!(synced_exact >= HIGH_CONFIDENCE_SYNCED_SCORE);
    }

    #[test]
    fn test_instrumental_placeholder_filter() {
        assert!(is_instrumental_placeholder("[00:00.00]纯音乐，请欣赏"));
        assert!(is_instrumental_placeholder("This song is an instrumental"));
        assert!(!is_usable_synced_lrc("[00:00.00]纯音乐，请欣赏"));
        assert!(!is_usable_synced_lrc(
            "[00:01.00]Only two lines\n[00:05.00]Should be rejected"
        ));
        assert!(is_usable_synced_lrc(
            "[00:01.00]First real lyric\n[00:05.00]Second real lyric\n[00:09.00]Third real lyric"
        ));
    }

    #[test]
    fn test_strip_tilde_and_anime_ost_suffixes() {
        assert_eq!(clean_for_lyrics_query("GO!!! ~NARUTO OPENING"), "GO!!!");
        assert_eq!(
            clean_for_lyrics_query("Blue Bird ～Naruto Shippuden OP～"),
            "Blue Bird"
        );
        assert_eq!(clean_for_lyrics_query("Sign - TV Size"), "Sign");
        assert_eq!(
            clean_for_lyrics_query("Silhouette - Opening Theme"),
            "Silhouette"
        );
    }

    #[test]
    fn test_parse_lrc_strips_enhanced_inline_word_timestamps() {
        let lrc = "[00:12.00]<00:12.00>We <00:12.40>are <00:12.80>fighting <00:13.20>dreamers\n[00:16.50]<00:16.50>高みを目指して";
        let parsed = parse_lrc(lrc);
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].text, "We are fighting dreamers");
        assert_eq!(parsed[1].text, "高みを目指して");
        assert!(!parsed[0].text.contains('<'));
        assert!(!parsed[1].text.contains('<'));
    }

    #[test]
    fn test_synced_first_never_blocked_by_higher_scoring_plain() {
        let dq = decompose_query_parts("GO!!! ~NARUTO OPENING", "FLOW", "", "", 93_000);
        let plain = ScoredCandidate {
            source: "lrclib".to_string(),
            title: "GO!!!".to_string(),
            artist: "FLOW".to_string(),
            duration_secs: Some(93),
            synced_lrc: None,
            plain_lyrics: Some(
                "We are fighting dreamers\nTakami wo mezashite\nFighting dreamers".to_string(),
            ),
            is_synced: false,
            is_instrumental: false,
            score: 95.0,
        };
        let synced = ScoredCandidate {
            source: "kugou".to_string(),
            title: "GO!!!".to_string(),
            artist: "FLOW".to_string(),
            duration_secs: Some(236),
            synced_lrc: Some(
                "[00:12.00]We are fighting dreamers\n[00:16.00]Line 2\n[00:20.00]Line 3"
                    .to_string(),
            ),
            plain_lyrics: None,
            is_synced: true,
            is_instrumental: false,
            score: 66.0,
        };

        let mut best_synced = None;
        let mut best_inst = None;
        let mut best_plain = None;
        record_candidate(plain, &dq, &mut best_synced, &mut best_inst, &mut best_plain);
        record_candidate(synced, &dq, &mut best_synced, &mut best_inst, &mut best_plain);

        let chosen = select_best_synced_first(best_synced, best_inst, best_plain)
            .expect("must pick synced");
        assert!(chosen.is_synced);
        assert_eq!(chosen.source, "kugou");
    }

    #[test]
    fn test_strict_gate_rejects_short_title_and_wrong_artist_false_positives() {
        let valid_lrc =
            "[00:05.00]Line one\n[00:10.00]Line two\n[00:15.00]Line three".to_string();

        // 1. Short title "99" by "MOB CHOIR" MUST reject synced "99 Problems" by "JAY-Z"
        let dq_99 = decompose_query_parts("99", "MOB CHOIR", "", "", 90_000);
        let jayz = ScoredCandidate {
            source: "lrclib".to_string(),
            title: "99 Problems".to_string(),
            artist: "JAY-Z".to_string(),
            duration_secs: Some(90),
            synced_lrc: Some(valid_lrc.clone()),
            plain_lyrics: None,
            is_synced: true,
            is_instrumental: false,
            score: 88.0,
        };
        assert!(!passes_auto_match_gates(&jayz, &dq_99));

        // Even same artist "MOB CHOIR" MUST reject "99 Problems" for short title "99"
        let wrong_title_same_artist = ScoredCandidate {
            artist: "MOB CHOIR".to_string(),
            ..jayz.clone()
        };
        assert!(!passes_auto_match_gates(&wrong_title_same_artist, &dq_99));

        // 2. "again" by "YUI" MUST reject synced "Again" by "Fetty Wap" (wrong artist)
        let dq_again = decompose_query_parts("again", "YUI", "", "", 254_000);
        let fetty = ScoredCandidate {
            source: "kugou".to_string(),
            title: "Again".to_string(),
            artist: "Fetty Wap".to_string(),
            duration_secs: Some(254),
            synced_lrc: Some(valid_lrc.clone()),
            plain_lyrics: None,
            is_synced: true,
            is_instrumental: false,
            score: 93.0,
        };
        assert!(!passes_auto_match_gates(&fetty, &dq_again));

        // 3. "GO!!! ~NARUTO OPENING" (93s) by "FLOW" MUST accept "GO!!!" by "FLOW"
        let dq_go = decompose_query_parts("GO!!! ~NARUTO OPENING", "FLOW", "", "", 93_000);
        let flow_full = ScoredCandidate {
            source: "netease".to_string(),
            title: "GO!!!".to_string(),
            artist: "FLOW".to_string(),
            duration_secs: Some(236),
            synced_lrc: Some(valid_lrc.clone()),
            plain_lyrics: None,
            is_synced: true,
            is_instrumental: false,
            score: 66.0,
        };
        assert!(passes_auto_match_gates(&flow_full, &dq_go));

        // 4. First timestamp after track duration MUST be rejected
        let after_end = ScoredCandidate {
            synced_lrc: Some(
                "[02:00.00]Too late 1\n[02:10.00]Too late 2\n[02:20.00]Too late 3".to_string(),
            ),
            ..flow_full
        };
        assert!(!passes_auto_match_gates(&after_end, &dq_go));
    }

    #[test]
    fn test_strict_gate_cjk_romaji_and_multi_artist_matching() {
        let sim_yk = artist_similarity("Yonezu Kenshi", "米津玄師");
        let sim_ky = artist_similarity("Kenshi Yonezu", "米津玄師");
        assert!(
            sim_yk >= 0.50,
            "Yonezu Kenshi vs 米津玄師 sim={sim_yk}, translit={:?}",
            transliterate_text("米津玄師")
        );
        assert!(
            sim_ky >= 0.50,
            "Kenshi Yonezu vs 米津玄師 sim={sim_ky}, translit={:?}",
            transliterate_text("米津玄師")
        );
        assert!(artist_similarity("Hitorie", "ヒトリエ") >= 0.95);
        assert!(artist_similarity("Aimer, SawanoHiroyuki", "Aimer") >= 0.95);
        assert!(artist_similarity("Fetty Wap", "YUI") < 0.20);
    }

    #[test]
    fn test_clear_auto_lyrics_cache_preserves_custom_and_manual_rows() {
        let dir = std::env::temp_dir().join(format!("sonea_clear_cache_{}", now_ts()));
        fs::create_dir_all(&dir).unwrap();
        let db = dir.join("test.sqlite3").to_string_lossy().to_string();
        crate::api::library::initialize_database(db.clone()).unwrap();

        {
            let conn = get_connection(&db).unwrap();
            conn.execute_batch(
                "INSERT INTO tracks(id,path,title,file_modified,added_at) VALUES
                    (1,'/a.flac','A',1,1),
                    (2,'/b.flac','B',1,1),
                    (3,'/c.flac','C',1,1),
                    (4,'/d.flac','D',1,1),
                    (5,'/e.flac','E',1,1);
                 INSERT INTO lyrics(track_id,source,synced_lrc,plain,status,fetched_at,last_attempt_at) VALUES
                    (1,'lrclib','[00:01.00]a',NULL,'found',1,1),
                    (2,'kugou','[00:01.00]b',NULL,'found',1,1),
                    (3,'cascade',NULL,NULL,'not_found',1,1),
                    (4,'manual','[00:01.00]manual',NULL,'found',1,1),
                    (5,'custom',NULL,'custom plain','found',1,1);",
            )
            .unwrap();
        }

        let cleared = clear_auto_lyrics_cache(db.clone()).unwrap();
        assert_eq!(cleared, 3);

        let conn = get_connection(&db).unwrap();
        let remaining: Vec<(i64, String)> = conn
            .prepare("SELECT track_id, source FROM lyrics ORDER BY track_id")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(
            remaining,
            vec![(4, "manual".to_string()), (5, "custom".to_string())]
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_validate_genius_url_blocks_spoofed_hosts() {
        assert!(validate_genius_url("https://genius.com/Flow-go-lyrics").is_some());
        assert!(validate_genius_url("http://genius.com/Flow-go-lyrics").is_none());
        assert!(validate_genius_url("https://genius.com@evil.example/lyrics").is_none());
        assert!(validate_genius_url("https://genius.com.evil.example/lyrics").is_none());
        assert!(validate_genius_url("https://127.0.0.1/genius.com").is_none());
    }

    #[test]
    fn test_is_likely_instrumental_metadata() {
        // Explicit vocal-less / instrumental markers -> true
        assert!(is_likely_instrumental_metadata(
            "Gurenge (Instrumental)",
            "Demon Slayer",
            "/music/02 Gurenge (Instrumental).flac"
        ));
        assert!(is_likely_instrumental_metadata(
            "Unravel (Off Vocal)",
            "",
            "/music/unravel.mp3"
        ));
        assert!(is_likely_instrumental_metadata(
            "Piano Sonata No. 14 in C-sharp minor",
            "Beethoven Complete Sonatas",
            "/music/moonlight.flac"
        ));
        assert!(is_likely_instrumental_metadata(
            "Main Theme (BGM)",
            "Anime OST",
            "/music/bgm01.mp3"
        ));
        assert!(is_likely_instrumental_metadata(
            "Cello Suite No. 1, BWV 1007: I. Prelude (Allegro)",
            "Bach",
            "/music/bwv1007.flac"
        ));

        // Normal vocal tracks -> false
        assert!(!is_likely_instrumental_metadata(
            "GO!!! ~NARUTO OPENING",
            "FLOW",
            "/music/FLOW - GO!!!.flac"
        ));
        assert!(!is_likely_instrumental_metadata(
            "again",
            "HOLIDAYS IN THE SUN",
            "/music/YUI - again.mp3"
        ));
        assert!(!is_likely_instrumental_metadata(
            "Righteous",
            "Legends Never Die",
            "/music/Juice WRLD - Righteous.flac"
        ));
    }

    #[test]
    fn test_provider_instrumental_flag_persists_in_sqlite() {
        let dir = std::env::temp_dir().join(format!("sonea_inst_persist_{}", now_ts()));
        fs::create_dir_all(&dir).unwrap();
        let db = dir.join("test.sqlite3").to_string_lossy().to_string();
        crate::api::library::initialize_database(db.clone()).unwrap();

        // 1. Verify LRCLIB instrumental:true produces a gated instrumental candidate
        let dq = decompose_query_parts(
            "River Flows in You",
            "Yiruma",
            "First Love",
            "/music/river.flac",
            188_000,
        );
        let lrclib_item = LrclibResponse {
            track_name: Some("River Flows in You".to_string()),
            artist_name: Some("Yiruma".to_string()),
            duration: Some(188.0),
            plain_lyrics: None,
            synced_lyrics: None,
            instrumental: Some(true),
        };
        let cand = extract_lrclib_candidate(lrclib_item, &dq).expect("instrumental candidate");
        assert!(cand.is_instrumental);
        assert!(passes_auto_match_gates(&cand, &dq));

        // Wrong artist must NOT pass instrumental confirmation gate
        let wrong_artist_cand = ScoredCandidate {
            artist: "Someone Else".to_string(),
            ..cand.clone()
        };
        assert!(!passes_auto_match_gates(&wrong_artist_cand, &dq));

        // 2. Verify SQLite persistence + Stage 0 cache hit + coverage + manual override
        {
            let conn = get_connection(&db).unwrap();
            conn.execute_batch(
                "INSERT INTO tracks(id,path,title,artist,duration_ms,file_modified,added_at) VALUES
                    (1,'/music/river.flac','River Flows in You','Yiruma',188000,1,1),
                    (2,'/music/unravel_inst.flac','Unravel (Instrumental)','TK',238000,1,1);
                 INSERT INTO lyrics(track_id,source,synced_lrc,plain,status,fetched_at,last_attempt_at) VALUES
                    (1,'lrclib',NULL,NULL,'instrumental',10,10);",
            )
            .unwrap();
        }

        // Cached provider instrumental row returns immediately with is_instrumental = true
        let cached = get_lyrics(db.clone(), 1, false, false)
            .unwrap()
            .expect("cached instrumental");
        assert!(cached.is_instrumental);
        assert!(!cached.is_synced);
        assert_eq!(cached.source, "lrclib");

        // Local heuristic (track 2) resolves in 0ms and persists status='instrumental'
        let heuristic = get_lyrics(db.clone(), 2, false, false)
            .unwrap()
            .expect("heuristic instrumental");
        assert!(heuristic.is_instrumental);
        assert_eq!(heuristic.source, "heuristic");

        // Coverage counts both instrumental rows accurately
        let stats = get_lyrics_coverage(db.clone()).unwrap();
        assert_eq!(stats.total_tracks, 2);
        assert_eq!(stats.instrumental_count, 2);
        assert_eq!(stats.synced_count, 0);

        // User saving custom lyrics overrides instrumental status
        save_custom_lyrics(
            db.clone(),
            1,
            Some("[00:01.00]Line 1\n[00:05.00]Line 2\n[00:09.00]Line 3".to_string()),
            None,
            "custom".to_string(),
        )
        .unwrap();
        let custom = get_lyrics(db.clone(), 1, false, false)
            .unwrap()
            .expect("custom lyrics override");
        assert!(!custom.is_instrumental);
        assert!(custom.is_synced);
        assert_eq!(custom.source, "custom");

        // clear_auto_lyrics_cache clears auto-detected instrumental (track 2) but preserves custom (track 1)
        let cleared = clear_auto_lyrics_cache(db.clone()).unwrap();
        assert_eq!(cleared, 1);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_rate_limit_cooldown_skips_and_resumes() {
        let base_now: u64 = 1_700_000_000;
        // Reset slot to 0 before asserting
        PROVIDER_COOLDOWN_UNTIL[ProviderId::Genius as usize].store(0, Ordering::Relaxed);
        assert!(!is_provider_in_cooldown_at(ProviderId::Genius, base_now));

        trigger_provider_cooldown_at(ProviderId::Genius, base_now, RATE_LIMIT_COOLDOWN_SECS);
        assert!(is_provider_in_cooldown_at(ProviderId::Genius, base_now));
        assert!(is_provider_in_cooldown_at(
            ProviderId::Genius,
            base_now + RATE_LIMIT_COOLDOWN_SECS - 1
        ));
        assert!(!is_provider_in_cooldown_at(
            ProviderId::Genius,
            base_now + RATE_LIMIT_COOLDOWN_SECS
        ));
        assert!(!is_provider_in_cooldown_at(
            ProviderId::Genius,
            base_now + RATE_LIMIT_COOLDOWN_SECS + 5
        ));
        // Clean up global slot so other tests are unaffected
        PROVIDER_COOLDOWN_UNTIL[ProviderId::Genius as usize].store(0, Ordering::Relaxed);
    }
}
