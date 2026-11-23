use crate::api::library::{get_connection, map_track, normalize_for_search, Track, TRACK_SELECT};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Component, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use std::time::Duration;

const MAX_COVER_DOWNLOAD_BYTES: u64 = 10 * 1024 * 1024; // 10 MiB
const MAX_MB_SEARCH_RESPONSE_BYTES: u64 = 2 * 1024 * 1024; // 2 MiB
static COVER_TMP_SEQ: AtomicU64 = AtomicU64::new(0);
static MB_HTTP_CLIENT: OnceLock<Result<reqwest::blocking::Client, String>> = OnceLock::new();
static COVER_HTTP_CLIENT: OnceLock<Result<reqwest::blocking::Client, String>> = OnceLock::new();

fn shared_mb_client() -> Result<&'static reqwest::blocking::Client, String> {
    MB_HTTP_CLIENT
        .get_or_init(|| {
            reqwest::blocking::Client::builder()
                .connect_timeout(Duration::from_secs(4))
                .timeout(Duration::from_secs(8))
                .https_only(true)
                .pool_max_idle_per_host(2)
                .redirect(reqwest::redirect::Policy::none())
                .user_agent("Sonea/1.0 (https://github.com/sonea-player/sonea)")
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(Clone::clone)
}

fn shared_cover_client() -> Result<&'static reqwest::blocking::Client, String> {
    COVER_HTTP_CLIENT
        .get_or_init(|| {
            let redirect_policy = reqwest::redirect::Policy::custom(|attempt| {
                if attempt.previous().len() >= 4 {
                    return attempt.error("Too many cover redirects");
                }
                if validate_trusted_cover_url(attempt.url().as_str()).is_ok() {
                    attempt.follow()
                } else {
                    attempt.error("Blocked redirect to untrusted cover host")
                }
            });
            reqwest::blocking::Client::builder()
                .connect_timeout(Duration::from_secs(4))
                .timeout(Duration::from_secs(10))
                .https_only(true)
                .pool_max_idle_per_host(2)
                .redirect(redirect_policy)
                .user_agent("Sonea/1.0 (https://github.com/sonea-player/sonea)")
                .build()
                .map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(Clone::clone)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MetadataCandidate {
    pub mbid: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub year: Option<i64>,
    pub cover_url: Option<String>,
}

#[derive(Deserialize)]
struct MbArtistCredit {
    name: Option<String>,
}

#[derive(Deserialize)]
struct MbRelease {
    id: Option<String>,
    title: Option<String>,
    date: Option<String>,
}

#[derive(Deserialize)]
struct MbRecording {
    id: String,
    title: String,
    #[serde(rename = "artist-credit")]
    artist_credit: Option<Vec<MbArtistCredit>>,
    releases: Option<Vec<MbRelease>>,
}

#[derive(Deserialize)]
struct MbSearchResponse {
    recordings: Option<Vec<MbRecording>>,
}

fn sanitize_query_term(input: &str) -> String {
    input
        .chars()
        .filter(|c| !c.is_control() && *c != '"')
        .take(180)
        .collect::<String>()
        .trim()
        .to_string()
}

fn parse_year_prefix(raw: &str) -> Option<i64> {
    let prefix: String = raw.trim().chars().take(4).collect();
    if prefix.len() == 4 && prefix.chars().all(|c| c.is_ascii_digit()) {
        prefix.parse::<i64>().ok().filter(|&y| (1000..=9999).contains(&y))
    } else {
        None
    }
}

/// Strictly parses URL with RFC-3986 parser and enforces HTTPS-only trusted hosts (CWE-918).
fn validate_trusted_cover_url(raw: &str) -> Result<reqwest::Url, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.len() > 1024 {
        return Err("Invalid cover URL length".to_string());
    }
    if trimmed.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("Cover URL contains invalid characters".to_string());
    }
    let parsed = reqwest::Url::parse(trimmed).map_err(|_| "Malformed cover URL".to_string())?;
    if parsed.scheme() != "https" {
        return Err("Only HTTPS cover URLs are allowed".to_string());
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err("Userinfo is not allowed in cover URL".to_string());
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| "Missing cover URL host".to_string())?
        .to_ascii_lowercase();
    let trusted = host == "coverartarchive.org"
        || host == "archive.org"
        || host.ends_with(".archive.org");
    if !trusted {
        return Err(format!("Untrusted cover host: {host}"));
    }
    Ok(parsed)
}

pub fn search_track_metadata(
    title: String,
    artist: Option<String>,
) -> Result<Vec<MetadataCandidate>, String> {
    let clean_title = sanitize_query_term(&title);
    if clean_title.is_empty() {
        return Ok(Vec::new());
    }

    let client = shared_mb_client()?;

    let query_str = if let Some(ref art) = artist {
        let clean_art = sanitize_query_term(art);
        if !clean_art.is_empty() {
            format!("recording:\"{clean_title}\" AND artist:\"{clean_art}\"")
        } else {
            format!("recording:\"{clean_title}\"")
        }
    } else {
        format!("recording:\"{clean_title}\"")
    };

    let url = format!(
        "https://musicbrainz.org/ws/2/recording/?query={}&fmt=json&limit=5",
        urlencode(&query_str)
    );

    let resp = client.get(&url).send().map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("MusicBrainz HTTP error: {}", resp.status()));
    }
    if resp
        .content_length()
        .is_some_and(|len| len > MAX_MB_SEARCH_RESPONSE_BYTES)
    {
        return Err("MusicBrainz response too large".to_string());
    }
    let mut body = Vec::new();
    resp.take(MAX_MB_SEARCH_RESPONSE_BYTES + 1)
        .read_to_end(&mut body)
        .map_err(|e| e.to_string())?;
    if (body.len() as u64) > MAX_MB_SEARCH_RESPONSE_BYTES {
        return Err("MusicBrainz response exceeded size cap".to_string());
    }

    let data: MbSearchResponse = serde_json::from_slice(&body).map_err(|e| e.to_string())?;
    let recordings = data.recordings.unwrap_or_default();

    let mut candidates = Vec::new();
    for rec in recordings {
        let rec_artist = rec
            .artist_credit
            .as_ref()
            .and_then(|ac| ac.first())
            .and_then(|a| a.name.clone())
            .unwrap_or_else(|| "Unknown Artist".to_string());

        let first_rel = rec.releases.as_ref().and_then(|r| r.first());
        let album = first_rel.and_then(|r| r.title.clone());
        let year = first_rel
            .and_then(|r| r.date.as_deref())
            .and_then(parse_year_prefix);

        let cover_url = first_rel.and_then(|r| {
            r.id.as_ref().and_then(|rel_id| {
                let valid_mbid = !rel_id.is_empty()
                    && rel_id.len() <= 64
                    && rel_id
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '-');
                if valid_mbid {
                    Some(format!("https://coverartarchive.org/release/{rel_id}/front-500"))
                } else {
                    None
                }
            })
        });

        candidates.push(MetadataCandidate {
            mbid: rec.id,
            title: rec.title,
            artist: rec_artist,
            album,
            year,
            cover_url,
        });
    }

    Ok(candidates)
}

#[allow(clippy::too_many_arguments)]
pub fn apply_track_metadata(
    db_path: String,
    covers_dir: String,
    track_id: i64,
    title: String,
    artist: String,
    album: Option<String>,
    year: Option<i64>,
    cover_url: Option<String>,
) -> Result<Track, String> {
    let dir = PathBuf::from(&covers_dir);
    if dir.components().any(|c| matches!(c, Component::ParentDir)) {
        return Err("Invalid covers directory path".to_string());
    }

    let conn = get_connection(&db_path)?;

    let mut new_cover_path: Option<String> = None;

    if let Some(url) = cover_url {
        if !url.trim().is_empty() {
            let safe_url = validate_trusted_cover_url(&url)?;
            let client = shared_cover_client()?;

            if let Ok(resp) = client.get(safe_url).send() {
                if resp.status().is_success() {
                    let too_large = resp
                        .content_length()
                        .is_some_and(|len| len > MAX_COVER_DOWNLOAD_BYTES);
                    if !too_large {
                        let mut bytes = Vec::new();
                        let read_ok = resp
                            .take(MAX_COVER_DOWNLOAD_BYTES + 1)
                            .read_to_end(&mut bytes)
                            .is_ok();
                        if read_ok
                            && !bytes.is_empty()
                            && (bytes.len() as u64) <= MAX_COVER_DOWNLOAD_BYTES
                        {
                            let mut hasher = Sha256::new();
                            hasher.update(&bytes);
                            let hash_bytes = hasher.finalize();
                            let hash = hash_bytes
                                .iter()
                                .map(|b| format!("{b:02x}"))
                                .collect::<String>();
                            let _ = fs::create_dir_all(&dir);
                            let dest = dir.join(format!("{hash}.jpg"));
                            let seq = COVER_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
                            let tmp_path = dir.join(format!("{hash}.{seq}.tmp"));

                            if let Ok(img) = image::load_from_memory(&bytes) {
                                let thumb_rgb = img.thumbnail(512, 512).to_rgb8();
                                if let Ok(mut out_file) = fs::File::create(&tmp_path) {
                                    let mut encoder =
                                        image::codecs::jpeg::JpegEncoder::new_with_quality(
                                            &mut out_file,
                                            82,
                                        );
                                    if encoder.encode_image(&thumb_rgb).is_ok()
                                        && fs::rename(&tmp_path, &dest).is_ok()
                                    {
                                        new_cover_path = dest.to_str().map(String::from);
                                    } else {
                                        let _ = fs::remove_file(&tmp_path);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    let norm_title = normalize_for_search(&title);
    let norm_art = normalize_for_search(&artist);
    let norm_alb = album.as_deref().map(normalize_for_search).unwrap_or_default();
    let search_text = format!("{norm_title} {norm_art} {norm_alb}");

    if let Some(cp) = new_cover_path {
        conn.execute(
            "UPDATE tracks SET title=?1, artist=?2, album=?3, year=?4, cover_path=?5, search_text=?6, norm_artist=?7, norm_album=?8 WHERE id=?9",
            params![title, artist, album, year, cp, search_text, norm_art, norm_alb, track_id],
        )
        .map_err(|e| e.to_string())?;
    } else {
        conn.execute(
            "UPDATE tracks SET title=?1, artist=?2, album=?3, year=?4, search_text=?5, norm_artist=?6, norm_album=?7 WHERE id=?8",
            params![title, artist, album, year, search_text, norm_art, norm_alb, track_id],
        )
        .map_err(|e| e.to_string())?;
    }

    let sql = format!("{TRACK_SELECT} WHERE t.id = ?1");
    conn.query_row(&sql, [track_id], map_track)
        .map_err(|e| e.to_string())
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
    fn test_metadata_candidate_serialize() {
        let candidate = MetadataCandidate {
            mbid: "test-mbid".to_string(),
            title: "Test Title".to_string(),
            artist: "Test Artist".to_string(),
            album: Some("Test Album".to_string()),
            year: Some(2024),
            cover_url: Some("https://coverartarchive.org/release/123/front-500".to_string()),
        };
        let json = serde_json::to_string(&candidate).unwrap();
        assert!(json.contains("test-mbid"));
    }

    #[test]
    fn test_cover_url_enforces_https_and_trusted_hosts() {
        assert!(validate_trusted_cover_url("http://coverartarchive.org/release/1/front").is_err());
        assert!(validate_trusted_cover_url("https://evil.example.com/x.jpg").is_err());
        assert!(validate_trusted_cover_url("https://127.0.0.1/secret").is_err());
        assert!(validate_trusted_cover_url("https://127.0.0.1?.archive.org").is_err());
        assert!(validate_trusted_cover_url("https://127.0.0.1#.archive.org").is_err());
        assert!(validate_trusted_cover_url("https://127.0.0.1\\.archive.org").is_err());
        assert!(validate_trusted_cover_url("https://coverartarchive.org@evil.com/x").is_err());
        assert!(validate_trusted_cover_url("https://coverartarchive.org/release/123/front-500").is_ok());
        assert!(validate_trusted_cover_url("https://ia800100.us.archive.org/item/cover.jpg").is_ok());
    }

    #[test]
    fn test_parse_year_prefix_handles_multibyte_utf8() {
        assert_eq!(parse_year_prefix("2024-08-01"), Some(2024));
        assert_eq!(parse_year_prefix("İstanbul"), None);
        assert_eq!(parse_year_prefix("日本語年"), None);
    }

    #[test]
    fn test_apply_track_metadata_updates_db() {
        let db_path = "file:test_apply_metadata?mode=memory&cache=shared";
        crate::api::library::initialize_database(db_path.to_string()).unwrap();
        let conn = get_connection(db_path).unwrap();

        conn.execute(
            "INSERT INTO tracks(path, title, file_modified, added_at) VALUES ('/test/song.mp3', 'Old Title', 1000, 1000)",
            [],
        )
        .unwrap();

        let track_id = conn.last_insert_rowid();

        let updated = apply_track_metadata(
            db_path.to_string(),
            "/tmp/covers".to_string(),
            track_id,
            "New Title".to_string(),
            "New Artist".to_string(),
            Some("New Album".to_string()),
            Some(2025),
            None,
        )
        .unwrap();

        assert_eq!(updated.title, "New Title");
        assert_eq!(updated.artist.as_deref(), Some("New Artist"));
        assert_eq!(updated.album.as_deref(), Some("New Album"));
        assert_eq!(updated.year, Some(2025));
    }
}
