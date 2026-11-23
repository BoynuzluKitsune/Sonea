use crate::frb_generated::StreamSink;
use lofty::config::{ParseOptions, ParsingMode};
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::Accessor;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::mem::ManuallyDrop;
use std::ops::{Deref, DerefMut};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use unicode_normalization::UnicodeNormalization;

const SCHEMA_VERSION: i32 = 8;
const EXTENSIONS: &[&str] = &["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff", "wv"];
const MAX_POOL_SIZE: usize = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SavedPlaybackState {
    pub queue_track_ids: Vec<i64>,
    pub current_index: i32,
    pub position_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Track {
    pub id: i64,
    pub path: String,
    pub title: String,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub duration_ms: Option<i64>,
    pub track_no: Option<i64>,
    pub year: Option<i64>,
    pub format: Option<String>,
    pub bitrate: Option<i64>,
    pub sample_rate: Option<i64>,
    pub bit_depth: Option<i64>,
    pub channels: Option<i64>,
    pub cover_path: Option<String>,
    pub file_modified: i64,
    pub added_at: i64,
    pub play_count: i64,
    pub last_played: Option<i64>,
    pub replaygain_track_gain: Option<f64>,
    pub replaygain_album_gain: Option<f64>,
    pub replaygain_track_peak: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaPath {
    pub path: String,
    pub file_modified: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanProgress {
    pub processed: u32,
    pub total: u32,
    pub current_path: String,
    pub finished: bool,
    pub error: Option<String>,
    pub indexed: u32,
    pub skipped: u32,
    pub unreadable: u32,
    pub scanned_count: u32,
    pub total_count: u32,
    pub found_count: u32,
}

/// Validates a filesystem path against null bytes, control chars, parent traversal (`..`),
/// and optional expected file extension (CWE-22).
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn validate_safe_file_path(
    raw: &str,
    required_ext: Option<&str>,
) -> Result<PathBuf, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("File path cannot be empty".to_string());
    }
    if trimmed.len() > 1024 {
        return Err("File path exceeds maximum allowed length".to_string());
    }
    if trimmed.bytes().any(|b| b == 0 || b == b'\n' || b == b'\r') {
        return Err("File path contains invalid control characters".to_string());
    }
    let path = PathBuf::from(trimmed);
    for comp in path.components() {
        if matches!(comp, Component::ParentDir) {
            return Err("Path traversal ('..') is not allowed".to_string());
        }
    }
    if let Some(ext) = required_ext {
        let actual = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase());
        if actual.as_deref() != Some(ext) {
            return Err(format!("Expected a .{ext} file path"));
        }
    }
    Ok(path)
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn escape_like_pattern(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for c in input.chars() {
        match c {
            '\\' | '%' | '_' => {
                out.push('\\');
                out.push(c);
            }
            other => out.push(other),
        }
    }
    out
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64
}

pub fn normalize_for_search(text: &str) -> String {
    let mut mapped = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            'İ' | 'I' | 'ı' => mapped.push('i'),
            other => mapped.push(other),
        }
    }
    let lower = mapped.to_lowercase();
    let stripped: String = lower
        .nfd()
        .filter(|&c| !('\u{0300}'..='\u{036F}').contains(&c))
        .collect();
    stripped.nfc().collect()
}

fn get_pool() -> &'static Mutex<HashMap<String, Vec<Connection>>> {
    static POOL: OnceLock<Mutex<HashMap<String, Vec<Connection>>>> = OnceLock::new();
    POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn get_migrated() -> &'static Mutex<HashSet<String>> {
    static MIGRATED: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    MIGRATED.get_or_init(|| Mutex::new(HashSet::new()))
}

pub(crate) struct PooledConn {
    conn: ManuallyDrop<Connection>,
    db_path: String,
}

impl Deref for PooledConn {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        &self.conn
    }
}

impl DerefMut for PooledConn {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.conn
    }
}

impl Drop for PooledConn {
    fn drop(&mut self) {
        // SAFETY: `self.conn` is never accessed again after `Drop::drop`.
        let conn = unsafe { ManuallyDrop::take(&mut self.conn) };
        if let Ok(mut pool) = get_pool().lock() {
            let list = pool.entry(self.db_path.clone()).or_default();
            if list.len() < MAX_POOL_SIZE {
                list.push(conn);
            }
        }
    }
}

pub(crate) fn get_connection(db_path: &str) -> Result<PooledConn, String> {
    if let Some(parent) = Path::new(db_path).parent() {
        if !db_path.is_empty() && db_path != ":memory:" {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
    }

    // Hold migration lock until migration succeeds so concurrent startup queries
    // never observe unmigrated tables, and failed migrations can be retried cleanly.
    let already_migrated = {
        let migrated = get_migrated().lock().map_err(|e| e.to_string())?;
        migrated.contains(db_path)
    };

    if already_migrated {
        if let Ok(mut pool) = get_pool().lock() {
            if let Some(list) = pool.get_mut(db_path) {
                if let Some(conn) = list.pop() {
                    return Ok(PooledConn {
                        conn: ManuallyDrop::new(conn),
                        db_path: db_path.to_string(),
                    });
                }
            }
        }
    }

    let conn = Connection::open(db_path).map_err(|e| e.to_string())?;
    let _ = conn.pragma_update(None, "journal_mode", "WAL");
    let _ = conn.pragma_update(None, "synchronous", "NORMAL");
    let _ = conn.pragma_update(None, "temp_store", "MEMORY");
    let _ = conn.pragma_update(None, "cache_size", -8000i64);
    conn.pragma_update(None, "foreign_keys", "ON").map_err(|e| e.to_string())?;
    conn.busy_timeout(std::time::Duration::from_secs(5)).map_err(|e| e.to_string())?;

    if !already_migrated {
        let mut migrated = get_migrated().lock().map_err(|e| e.to_string())?;
        if !migrated.contains(db_path) {
            migrate(&conn)?;
            migrated.insert(db_path.to_string());
        }
    }

    Ok(PooledConn {
        conn: ManuallyDrop::new(conn),
        db_path: db_path.to_string(),
    })
}

fn migrate(conn: &Connection) -> Result<(), String> {
    let version: i32 = conn
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .map_err(|e| e.to_string())?;
    if version > SCHEMA_VERSION {
        return Err(format!(
            "Database schema {version} is newer than supported schema {SCHEMA_VERSION}"
        ));
    }
    if version < 1 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                artist TEXT,
                album TEXT,
                album_artist TEXT,
                duration_ms INTEGER,
                track_no INTEGER,
                year INTEGER,
                format TEXT,
                bitrate INTEGER,
                sample_rate INTEGER,
                bit_depth INTEGER,
                channels INTEGER,
                cover_path TEXT,
                file_modified INTEGER NOT NULL,
                file_size INTEGER NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL,
                unreadable INTEGER NOT NULL DEFAULT 0,
                search_text TEXT NOT NULL DEFAULT '',
                norm_artist TEXT NOT NULL DEFAULT '',
                norm_album TEXT NOT NULL DEFAULT '',
                replaygain_track_gain REAL,
                replaygain_album_gain REAL,
                replaygain_track_peak REAL
            );
            CREATE TABLE favorites (track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE, added_at INTEGER NOT NULL);
            CREATE TABLE play_stats (track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE, play_count INTEGER NOT NULL DEFAULT 0, last_played INTEGER);
            CREATE INDEX tracks_title_idx ON tracks(title COLLATE NOCASE);
            CREATE INDEX tracks_artist_idx ON tracks(artist COLLATE NOCASE);
            CREATE INDEX tracks_album_idx ON tracks(album COLLATE NOCASE);
            CREATE INDEX tracks_search_idx ON tracks(search_text);
            CREATE INDEX tracks_unreadable_idx ON tracks(unreadable);
            CREATE TABLE IF NOT EXISTS playback_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                queue_json TEXT NOT NULL,
                current_index INTEGER NOT NULL,
                position_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS lyrics (
                track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                synced_lrc TEXT,
                plain TEXT,
                status TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                last_attempt_at INTEGER NOT NULL
            );
            CREATE INDEX lyrics_status_idx ON lyrics(status);
            CREATE TABLE IF NOT EXISTS playlists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS playlist_entries (
                playlist_id INTEGER REFERENCES playlists(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
                PRIMARY KEY (playlist_id, position)
            );
            CREATE INDEX playlist_entries_track_idx ON playlist_entries(track_id);
            PRAGMA user_version = 8;",
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        return Ok(());
    }
    if version < 2 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "ALTER TABLE tracks ADD COLUMN unreadable INTEGER NOT NULL DEFAULT 0;
             ALTER TABLE tracks ADD COLUMN search_text TEXT NOT NULL DEFAULT '';
             ALTER TABLE tracks ADD COLUMN norm_artist TEXT NOT NULL DEFAULT '';
             ALTER TABLE tracks ADD COLUMN norm_album TEXT NOT NULL DEFAULT '';
             CREATE INDEX IF NOT EXISTS tracks_search_idx ON tracks(search_text);
             CREATE INDEX IF NOT EXISTS tracks_unreadable_idx ON tracks(unreadable);
             UPDATE tracks SET unreadable = 1 WHERE duration_ms IS NULL;",
        )
        .map_err(|e| e.to_string())?;

        struct MigrationRow {
            id: i64,
            title: String,
            artist: Option<String>,
            album: Option<String>,
            album_artist: Option<String>,
        }

        let rows: Vec<MigrationRow> = {
            let mut stmt = tx
                .prepare("SELECT id, title, artist, album, album_artist FROM tracks")
                .map_err(|e| e.to_string())?;
            let mapped = stmt
                .query_map([], |r| {
                    Ok(MigrationRow {
                        id: r.get(0)?,
                        title: r.get(1)?,
                        artist: r.get(2)?,
                        album: r.get(3)?,
                        album_artist: r.get(4)?,
                    })
                })
                .map_err(|e| e.to_string())?;
            let mut items = Vec::new();
            for item in mapped {
                items.push(item.map_err(|e| e.to_string())?);
            }
            items
        };

        for row in rows {
            let norm_title = normalize_for_search(&row.title);
            let norm_art = row.artist.as_deref().map(normalize_for_search).unwrap_or_default();
            let norm_alb = row.album.as_deref().map(normalize_for_search).unwrap_or_default();
            let norm_alb_art = row
                .album_artist
                .as_deref()
                .map(normalize_for_search)
                .unwrap_or_default();
            let search_text = format!("{norm_title} {norm_art} {norm_alb} {norm_alb_art}");
            tx.execute(
                "UPDATE tracks SET search_text = ?1, norm_artist = ?2, norm_album = ?3 WHERE id = ?4",
                params![search_text, norm_art, norm_alb, row.id],
            )
            .map_err(|e| e.to_string())?;
        }

        tx.execute_batch("PRAGMA user_version = 2;").map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    if version < 3 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS playback_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                queue_json TEXT NOT NULL,
                current_index INTEGER NOT NULL,
                position_ms INTEGER NOT NULL
            );
            PRAGMA user_version = 3;",
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    if version < 4 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS lyrics (
                track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                synced_lrc TEXT,
                plain TEXT,
                status TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                last_attempt_at INTEGER NOT NULL
            );
            PRAGMA user_version = 4;",
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    if version < 5 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "CREATE TABLE IF NOT EXISTS playlists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS playlist_entries (
                playlist_id INTEGER REFERENCES playlists(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
                PRIMARY KEY (playlist_id, position)
            );
            PRAGMA user_version = 5;",
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    if version < 6 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "ALTER TABLE tracks ADD COLUMN replaygain_track_gain REAL;
             ALTER TABLE tracks ADD COLUMN replaygain_album_gain REAL;
             ALTER TABLE tracks ADD COLUMN replaygain_track_peak REAL;
             PRAGMA user_version = 6;",
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    if version < 7 {
        let has_file_size: bool = conn
            .prepare("PRAGMA table_info(tracks)")
            .and_then(|mut stmt| {
                let names: Vec<String> = stmt
                    .query_map([], |r| r.get::<_, String>(1))?
                    .filter_map(Result::ok)
                    .collect();
                Ok(names.iter().any(|n| n == "file_size"))
            })
            .unwrap_or(false);
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        if !has_file_size {
            tx.execute_batch("ALTER TABLE tracks ADD COLUMN file_size INTEGER NOT NULL DEFAULT 0;")
                .map_err(|e| e.to_string())?;
        }
        tx.execute_batch("PRAGMA user_version = 7;")
            .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    if version < 8 {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute_batch(
            "CREATE INDEX IF NOT EXISTS tracks_album_idx ON tracks(album COLLATE NOCASE);
             CREATE TABLE IF NOT EXISTS lyrics (
                 track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                 source TEXT NOT NULL,
                 synced_lrc TEXT,
                 plain TEXT,
                 status TEXT NOT NULL,
                 fetched_at INTEGER NOT NULL,
                 last_attempt_at INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS lyrics_status_idx ON lyrics(status);
             CREATE TABLE IF NOT EXISTS playlists (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 name TEXT NOT NULL,
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS playlist_entries (
                 playlist_id INTEGER REFERENCES playlists(id) ON DELETE CASCADE,
                 position INTEGER NOT NULL,
                 track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
                 PRIMARY KEY (playlist_id, position)
             );
             CREATE INDEX IF NOT EXISTS playlist_entries_track_idx ON playlist_entries(track_id);
             PRAGMA user_version = 8;",
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn initialize_database(db_path: String) -> Result<(), String> {
    get_connection(&db_path).map(|_| ())
}

pub(crate) fn map_track(row: &rusqlite::Row<'_>) -> rusqlite::Result<Track> {
    Ok(Track {
        id: row.get(0)?,
        path: row.get(1)?,
        title: row.get(2)?,
        artist: row.get(3)?,
        album: row.get(4)?,
        album_artist: row.get(5)?,
        duration_ms: row.get(6)?,
        track_no: row.get(7)?,
        year: row.get(8)?,
        format: row.get(9)?,
        bitrate: row.get(10)?,
        sample_rate: row.get(11)?,
        bit_depth: row.get(12)?,
        channels: row.get(13)?,
        cover_path: row.get(14)?,
        file_modified: row.get(15)?,
        added_at: row.get(16)?,
        play_count: row.get(17)?,
        last_played: row.get(18)?,
        replaygain_track_gain: row.get(19)?,
        replaygain_album_gain: row.get(20)?,
        replaygain_track_peak: row.get(21)?,
    })
}

pub const TRACK_SELECT: &str = "SELECT t.id,t.path,t.title,t.artist,t.album,t.album_artist,t.duration_ms,t.track_no,t.year,t.format,t.bitrate,t.sample_rate,t.bit_depth,t.channels,t.cover_path,t.file_modified,t.added_at,COALESCE(p.play_count,0),p.last_played,t.replaygain_track_gain,t.replaygain_album_gain,t.replaygain_track_peak FROM tracks t LEFT JOIN play_stats p ON p.track_id=t.id";

pub fn search_tracks(db_path: String, query: String) -> Result<Vec<Track>, String> {
    let conn = get_connection(&db_path)?;
    let trimmed = query.trim();
    let norm_query = escape_like_pattern(&normalize_for_search(trimmed));
    let pat = format!("%{norm_query}%");
    let sql = format!("{TRACK_SELECT} WHERE t.unreadable = 0 AND (?1 = '' OR t.search_text LIKE ?2 ESCAPE '\\') ORDER BY t.title COLLATE NOCASE");
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![trimmed, pat], map_track)
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn list_albums(db_path: String, query: String) -> Result<Vec<String>, String> {
    list_group(&db_path, &query, "album")
}

pub fn list_artists(db_path: String, query: String) -> Result<Vec<String>, String> {
    list_group(&db_path, &query, "artist")
}

fn list_group(db_path: &str, query: &str, column: &str) -> Result<Vec<String>, String> {
    let (safe_col, norm_col) = match column {
        "artist" => ("artist", "norm_artist"),
        "album" => ("album", "norm_album"),
        _ => return Err("Invalid group column".to_string()),
    };
    let conn = get_connection(db_path)?;
    let trimmed = query.trim();
    let norm_query = escape_like_pattern(&normalize_for_search(trimmed));
    let pat = format!("%{norm_query}%");
    let sql = format!("SELECT DISTINCT {safe_col} FROM tracks WHERE unreadable = 0 AND {safe_col} IS NOT NULL AND {safe_col} != '' AND (?1 = '' OR {norm_col} LIKE ?2 ESCAPE '\\') ORDER BY {safe_col} COLLATE NOCASE");
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![trimmed, pat], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

struct ParsedTrack {
    path: String,
    title: String,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    duration_ms: Option<i64>,
    track_no: Option<i64>,
    year: Option<i64>,
    format: Option<String>,
    bitrate: Option<i64>,
    sample_rate: Option<i64>,
    bit_depth: Option<i64>,
    channels: Option<i64>,
    cover_path: Option<String>,
    file_modified: i64,
    file_size: i64,
    unreadable: bool,
    search_text: String,
    norm_artist: String,
    norm_album: String,
    rg_track_gain: Option<f64>,
    rg_album_gain: Option<f64>,
    rg_track_peak: Option<f64>,
}

const UPSERT_TRACK_SQL: &str = "INSERT INTO tracks(
    path,title,artist,album,album_artist,duration_ms,track_no,year,format,
    bitrate,sample_rate,bit_depth,channels,cover_path,file_modified,file_size,added_at,
    unreadable,search_text,norm_artist,norm_album,replaygain_track_gain,replaygain_album_gain,replaygain_track_peak
) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24)
ON CONFLICT(path) DO UPDATE SET
    title=excluded.title,
    artist=excluded.artist,
    album=excluded.album,
    album_artist=excluded.album_artist,
    duration_ms=excluded.duration_ms,
    track_no=excluded.track_no,
    year=excluded.year,
    format=excluded.format,
    bitrate=excluded.bitrate,
    sample_rate=excluded.sample_rate,
    bit_depth=excluded.bit_depth,
    channels=excluded.channels,
    cover_path=excluded.cover_path,
    file_modified=excluded.file_modified,
    file_size=excluded.file_size,
    unreadable=excluded.unreadable,
    search_text=excluded.search_text,
    norm_artist=excluded.norm_artist,
    norm_album=excluded.norm_album,
    replaygain_track_gain=excluded.replaygain_track_gain,
    replaygain_album_gain=excluded.replaygain_album_gain,
    replaygain_track_peak=excluded.replaygain_track_peak";

#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Default, Clone, Copy)]
struct IncrementalScanStats {
    total: u32,
    #[cfg_attr(not(test), allow(dead_code))]
    indexed: u32,
    #[cfg_attr(not(test), allow(dead_code))]
    skipped: u32,
    #[allow(dead_code)]
    unreadable: u32,
}

fn preload_cover_cache(covers_dir: &Path) -> HashMap<String, String> {
    let mut cache = HashMap::new();
    if let Ok(entries) = fs::read_dir(covers_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) == Some("jpg") {
                let valid = entry.metadata().map(|m| m.is_file() && m.len() > 0).unwrap_or(false);
                if valid {
                    if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                        cache.insert(stem.to_string(), p.to_string_lossy().to_string());
                    }
                }
            }
        }
    }
    cache
}

fn find_sidecar_cover_bytes(audio_path: &Path) -> Option<Vec<u8>> {
    let dir = audio_path.parent()?;
    const NAMES: &[&str] = &[
        "cover.jpg",
        "cover.jpeg",
        "cover.png",
        "folder.jpg",
        "folder.jpeg",
        "folder.png",
        "front.jpg",
        "front.jpeg",
        "front.png",
        "album.jpg",
        "album.png",
    ];
    let entries = fs::read_dir(dir).ok()?;
    let mut best: Option<PathBuf> = None;
    let mut best_rank = usize::MAX;
    for entry in entries.flatten() {
        let p = entry.path();
        let is_regular_file = fs::symlink_metadata(&p)
            .map(|m| m.file_type().is_file())
            .unwrap_or(false);
        if !is_regular_file {
            continue;
        }
        let Some(fname) = p.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let lower = fname.to_ascii_lowercase();
        if let Some(rank) = NAMES.iter().position(|&cand| cand == lower) {
            if rank < best_rank {
                best_rank = rank;
                best = Some(p);
                if rank == 0 {
                    break;
                }
            }
        }
    }
    let chosen = best?;
    let meta = fs::metadata(&chosen).ok()?;
    if meta.len() == 0 || meta.len() > 16 * 1024 * 1024 {
        return None;
    }
    fs::read(chosen).ok()
}

fn run_incremental_scan<F>(
    conn: &Connection,
    covers_dir: &Path,
    paths: Vec<MediaPath>,
    on_progress: F,
) -> Result<IncrementalScanStats, String>
where
    F: FnMut(ScanProgress) + Send,
{
    if covers_dir
        .components()
        .any(|c| matches!(c, Component::ParentDir))
    {
        return Err("Invalid covers directory path".to_string());
    }
    fs::create_dir_all(covers_dir).map_err(|e| e.to_string())?;

    let total_usize = paths.len();
    let total = total_usize as u32;
    let mut seen = Vec::with_capacity(paths.len());
    let mut to_parse: Vec<(String, i64, i64)> = Vec::new();

    // Live atomic counters updated on every single file across filter + parallel parse phases.
    let scanned_count = AtomicUsize::new(0);
    let found_count = AtomicUsize::new(0);
    let skipped_count = AtomicUsize::new(0);
    let unreadable_count = AtomicUsize::new(0);
    let indexed_count = AtomicUsize::new(0);
    let scan_start = Instant::now();
    let last_emit_ms = AtomicU64::new(0);
    let progress_cb = Mutex::new((0u32, on_progress));

    let emit_progress = |force: bool, current_path: &str, finished: bool| {
        let elapsed_ms = scan_start.elapsed().as_millis() as u64;
        if !force {
            let prev = last_emit_ms.load(Ordering::Relaxed);
            if elapsed_ms.saturating_sub(prev) < 85 {
                return;
            }
            if last_emit_ms
                .compare_exchange(prev, elapsed_ms, Ordering::AcqRel, Ordering::Relaxed)
                .is_err()
            {
                return;
            }
        } else {
            last_emit_ms.store(elapsed_ms, Ordering::Release);
        }

        if let Ok(mut guard) = progress_cb.lock() {
            let (ref mut max_emitted, ref mut cb) = *guard;
            let raw_processed = if finished {
                total
            } else {
                (scanned_count.load(Ordering::Acquire).min(total_usize)) as u32
            };
            let processed = raw_processed.max(*max_emitted).min(total);
            *max_emitted = processed;

            let found = found_count.load(Ordering::Acquire).min(total_usize) as u32;
            let indexed = indexed_count.load(Ordering::Acquire).min(total_usize) as u32;
            let skipped = skipped_count.load(Ordering::Acquire).min(total_usize) as u32;
            let unreadable = unreadable_count.load(Ordering::Acquire).min(total_usize) as u32;

            cb(ScanProgress {
                processed,
                total,
                current_path: current_path.to_string(),
                finished,
                error: None,
                indexed,
                skipped,
                unreadable,
                scanned_count: processed,
                total_count: total,
                found_count: found,
            });
        }
    };

    // Emit initial snapshot immediately so UI never stays stuck at "0 / 0".
    if total > 0 {
        emit_progress(true, "", false);
    }

    // 1. Pre-fetch existing (path -> (file_modified, file_size, unreadable, cover_path)) in a single fast query.
    let mut existing_map: HashMap<String, (i64, i64, i64, Option<String>)> = HashMap::new();
    if let Ok(mut stmt) = conn.prepare("SELECT path, file_modified, file_size, unreadable, cover_path FROM tracks") {
        if let Ok(rows) = stmt.query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
        }) {
            for r in rows.flatten() {
                existing_map.insert(r.0, (r.1, r.2, r.3, r.4));
            }
        }
    }

    // 2. Fast incremental filter: skip unchanged files without opening or parsing tags,
    //    unless their previously cached cover file was deleted or corrupted on disk.
    for item in paths {
        let path = Path::new(&item.path);
        if !is_audio(path) {
            scanned_count.fetch_add(1, Ordering::Relaxed);
            emit_progress(false, &item.path, false);
            continue;
        }
        let meta = match fs::metadata(path) {
            Ok(m) if m.is_file() => m,
            _ => {
                scanned_count.fetch_add(1, Ordering::Relaxed);
                emit_progress(false, &item.path, false);
                continue;
            }
        };
        let disk_size = meta.len() as i64;
        seen.push(item.path.clone());

        if let Some((old_mod, old_size, old_unread, old_cover)) = existing_map.get(&item.path) {
            let size_unchanged = *old_size == 0 || *old_size == disk_size;
            let cover_intact = match old_cover.as_deref() {
                Some(cp) if !cp.trim().is_empty() => {
                    fs::metadata(cp).map(|m| m.is_file() && m.len() > 0).unwrap_or(false)
                }
                _ => true,
            };
            if *old_mod == item.file_modified && size_unchanged && cover_intact {
                skipped_count.fetch_add(1, Ordering::Relaxed);
                if *old_unread == 1 {
                    unreadable_count.fetch_add(1, Ordering::Relaxed);
                } else {
                    found_count.fetch_add(1, Ordering::Relaxed);
                }
                let done = scanned_count.fetch_add(1, Ordering::Relaxed) + 1;
                emit_progress(done == 1, &item.path, false);
                continue;
            }
        }

        to_parse.push((item.path, item.file_modified, disk_size));
    }

    // Force an update after fast-skip filtering if any files were skipped.
    if skipped_count.load(Ordering::Relaxed) > 0 && !to_parse.is_empty() {
        emit_progress(true, "", false);
    }

    // 3. Parse only new or modified files in parallel using a bounded thread pool (2..=4 threads),
    //    streaming live progress updates via AtomicUsize every ~85ms.
    let parsed_tracks: Vec<ParsedTrack> = if to_parse.is_empty() {
        Vec::new()
    } else {
        let cover_cache = Mutex::new(preload_cover_cache(covers_dir));
        let next_idx = AtomicUsize::new(0);
        let worker_count = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(2)
            .clamp(2, 4)
            .min(to_parse.len());

        let results: Mutex<Vec<ParsedTrack>> = Mutex::new(Vec::with_capacity(to_parse.len()));
        std::thread::scope(|s| {
            for _ in 0..worker_count {
                let to_parse_ref = &to_parse;
                let next_idx_ref = &next_idx;
                let cover_cache_ref = &cover_cache;
                let results_ref = &results;
                let scanned_ref = &scanned_count;
                let found_ref = &found_count;
                let unreadable_ref = &unreadable_count;
                let indexed_ref = &indexed_count;
                let emit_ref = &emit_progress;
                s.spawn(move || {
                    let mut local = Vec::new();
                    loop {
                        let idx = next_idx_ref.fetch_add(1, Ordering::Relaxed);
                        if idx >= to_parse_ref.len() {
                            break;
                        }
                        let (ref p_str, modified, file_size) = to_parse_ref[idx];
                        let parsed = parse_audio_metadata(
                            Path::new(p_str),
                            modified,
                            file_size,
                            covers_dir,
                            Some(cover_cache_ref),
                        );
                        if parsed.unreadable {
                            unreadable_ref.fetch_add(1, Ordering::Relaxed);
                        } else {
                            found_ref.fetch_add(1, Ordering::Relaxed);
                        }
                        indexed_ref.fetch_add(1, Ordering::Relaxed);
                        let done = scanned_ref.fetch_add(1, Ordering::Relaxed) + 1;
                        emit_ref(done == 1, &parsed.path, false);
                        local.push(parsed);
                    }
                    if let Ok(mut guard) = results_ref.lock() {
                        guard.extend(local);
                    }
                });
            }
        });
        results.into_inner().unwrap_or_default()
    };

    // 4. Bulk upsert in 500-row transactions + remove missing tracks.
    let mut committed_indexed: u32 = 0;
    let ts = now();

    for chunk in parsed_tracks.chunks(500) {
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        {
            let mut stmt = tx.prepare(UPSERT_TRACK_SQL).map_err(|e| e.to_string())?;
            for track in chunk {
                let unreadable_int: i64 = if track.unreadable { 1 } else { 0 };
                stmt.execute(params![
                    track.path,
                    track.title,
                    track.artist,
                    track.album,
                    track.album_artist,
                    track.duration_ms,
                    track.track_no,
                    track.year,
                    track.format,
                    track.bitrate,
                    track.sample_rate,
                    track.bit_depth,
                    track.channels,
                    track.cover_path,
                    track.file_modified,
                    track.file_size,
                    ts,
                    unreadable_int,
                    track.search_text,
                    track.norm_artist,
                    track.norm_album,
                    track.rg_track_gain,
                    track.rg_album_gain,
                    track.rg_track_peak,
                ])
                .map_err(|e| e.to_string())?;
                committed_indexed += 1;
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
        emit_progress(
            false,
            chunk.last().map(|t| t.path.as_str()).unwrap_or(""),
            false,
        );
    }

    remove_missing_tracks(conn, &seen)?;

    let skipped = skipped_count.load(Ordering::Relaxed) as u32;
    let unreadable = unreadable_count.load(Ordering::Relaxed) as u32;
    indexed_count.store(committed_indexed as usize, Ordering::Relaxed);

    emit_progress(true, "", true);

    Ok(IncrementalScanStats {
        total,
        indexed: committed_indexed,
        skipped,
        unreadable,
    })
}

pub fn scan_paths(
    db_path: String,
    cache_dir: String,
    paths: Vec<MediaPath>,
    sink: StreamSink<String>,
) -> Result<u32, String> {
    let conn = get_connection(&db_path)?;
    let covers_dir = PathBuf::from(cache_dir).join("covers");

    let stats = run_incremental_scan(&conn, &covers_dir, paths, |progress| {
        if let Ok(json) = serde_json::to_string(&progress) {
            let _ = sink.add(json);
        }
    })?;

    Ok(stats.total)
}

fn remove_missing_tracks(conn: &Connection, seen: &[String]) -> Result<(), String> {
    if seen.is_empty() {
        // Preserve existing library & favorites if MediaStore temporarily returns empty (e.g. unmounted SD).
        return Ok(());
    }
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute(
        "DELETE FROM tracks WHERE path NOT IN (SELECT value FROM json_each(?1))",
        [serde_json::to_string(seen).map_err(|e| e.to_string())?],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

fn is_audio(path: &Path) -> bool {
    path.extension()
        .and_then(|v| v.to_str())
        .is_some_and(|e| EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
}

fn parse_audio_metadata(
    path: &Path,
    modified: i64,
    file_size: i64,
    covers: &Path,
    cover_cache: Option<&Mutex<HashMap<String, String>>>,
) -> ParsedTrack {
    let display = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("Unknown track")
        .to_string();

    let parse_options = ParseOptions::new().parsing_mode(ParsingMode::Relaxed);
    let parsed = if file_size <= 0 {
        log::debug!("Audio unreadable: empty file");
        None
    } else {
        match Probe::open(path) {
            Ok(probe) => match probe.options(parse_options).read() {
                Ok(file) => Some(file),
                Err(e) => {
                    log::debug!("Audio unreadable: parse error ({:?})", e);
                    None
                }
            },
            Err(e) => {
                log::debug!("Audio unreadable: open error ({:?})", e);
                None
            }
        }
    };
    let unreadable = parsed.is_none();
    let mut title = display.clone();
    let mut artist = None;
    let mut album = None;
    let mut album_artist = None;
    let mut track_no = None;
    let mut year = None;
    let mut cover_path = None;
    let mut rg_track_gain: Option<f64> = None;
    let mut rg_album_gain: Option<f64> = None;
    let mut rg_track_peak: Option<f64> = None;

    let parse_rg = |v: &str| -> Option<f64> {
        v.replace("dB", "").replace("db", "").trim().parse::<f64>().ok()
    };

    let (duration_ms, bitrate, sample_rate, bit_depth, channels, format) = if let Some(file) = parsed {
        let tag = file.primary_tag().or_else(|| file.first_tag());
        if let Some(tag) = tag {
            title = tag
                .title()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or(display);
            artist = tag
                .artist()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            album = tag
                .album()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            album_artist = tag
                .get_string(lofty::tag::ItemKey::AlbumArtist)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            track_no = tag.track().map(i64::from);
            year = tag
                .get_string(lofty::tag::ItemKey::Year)
                .or_else(|| tag.get_string(lofty::tag::ItemKey::RecordingDate))
                .and_then(parse_year_str);
            if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainTrackGain) {
                rg_track_gain = parse_rg(val);
            }
            if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainAlbumGain) {
                rg_album_gain = parse_rg(val);
            }
            if let Some(val) = tag.get_string(lofty::tag::ItemKey::ReplayGainTrackPeak) {
                rg_track_peak = parse_rg(val);
            }
        }
        // Search across ALL tags in the file (ID3v2, VorbisComments, MP4, APE, etc.)
        // because FLAC/MP3 files often store CoverFront outside the primary tag.
        let preferred_pic = file
            .tags()
            .iter()
            .flat_map(|t| t.pictures().iter())
            .find(|p| p.pic_type() == lofty::picture::PictureType::CoverFront)
            .or_else(|| file.tags().iter().flat_map(|t| t.pictures().iter()).next());
        if let Some(pic) = preferred_pic {
            cover_path = cache_cover_dedup(pic.data(), covers, cover_cache);
        }
        if cover_path.is_none() {
            if let Some(sidecar) = find_sidecar_cover_bytes(path) {
                cover_path = cache_cover_dedup(&sidecar, covers, cover_cache);
            }
        }
        let props = file.properties();
        (
            Some(props.duration().as_millis() as i64),
            Some(i64::from(props.audio_bitrate().unwrap_or(0))),
            Some(i64::from(props.sample_rate().unwrap_or(0))),
            props.bit_depth().map(i64::from),
            Some(i64::from(props.channels().unwrap_or(0))),
            path.extension().and_then(|x| x.to_str()).map(str::to_uppercase),
        )
    } else {
        (
            None,
            None,
            None,
            None,
            None,
            path.extension().and_then(|x| x.to_str()).map(str::to_uppercase),
        )
    };

    let norm_title = normalize_for_search(&title);
    let norm_art = artist.as_deref().map(normalize_for_search).unwrap_or_default();
    let norm_alb = album.as_deref().map(normalize_for_search).unwrap_or_default();
    let norm_alb_art = album_artist
        .as_deref()
        .map(normalize_for_search)
        .unwrap_or_default();
    let search_text = format!("{norm_title} {norm_art} {norm_alb} {norm_alb_art}");

    ParsedTrack {
        path: path.to_string_lossy().to_string(),
        title,
        artist,
        album,
        album_artist,
        duration_ms,
        track_no,
        year,
        format,
        bitrate,
        sample_rate,
        bit_depth,
        channels,
        cover_path,
        file_modified: modified,
        file_size,
        unreadable,
        search_text,
        norm_artist: norm_art,
        norm_album: norm_alb,
        rg_track_gain,
        rg_album_gain,
        rg_track_peak,
    }
}

#[cfg_attr(not(test), allow(dead_code))]
fn index_file(conn: &Connection, path: &Path, modified: i64, covers: &Path) -> Result<bool, String> {
    let file_size = fs::metadata(path).map(|m| m.len() as i64).unwrap_or(0);
    let track = parse_audio_metadata(path, modified, file_size, covers, None);
    let unreadable_int: i64 = if track.unreadable { 1 } else { 0 };
    conn.execute(
        UPSERT_TRACK_SQL,
        params![
            track.path,
            track.title,
            track.artist,
            track.album,
            track.album_artist,
            track.duration_ms,
            track.track_no,
            track.year,
            track.format,
            track.bitrate,
            track.sample_rate,
            track.bit_depth,
            track.channels,
            track.cover_path,
            track.file_modified,
            track.file_size,
            now(),
            unreadable_int,
            track.search_text,
            track.norm_artist,
            track.norm_album,
            track.rg_track_gain,
            track.rg_album_gain,
            track.rg_track_peak,
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(track.unreadable)
}

fn parse_year_str(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    if trimmed.len() < 4 {
        return None;
    }
    let prefix: String = trimmed.chars().take(4).collect();
    if prefix.len() == 4 && prefix.chars().all(|c| c.is_ascii_digit()) {
        prefix.parse::<i64>().ok().filter(|&y| (1000..=9999).contains(&y))
    } else {
        None
    }
}

fn cache_cover_dedup(
    bytes: &[u8],
    covers: &Path,
    cover_cache: Option<&Mutex<HashMap<String, String>>>,
) -> Option<String> {
    if bytes.is_empty() || bytes.len() > 20 * 1024 * 1024 {
        return None;
    }
    if covers.components().any(|c| matches!(c, Component::ParentDir)) {
        return None;
    }
    let digest = Sha256::digest(bytes);
    let key = digest
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();

    if let Some(cache_mutex) = cover_cache {
        if let Ok(cache) = cache_mutex.lock() {
            if let Some(existing_path) = cache.get(&key) {
                return Some(existing_path.clone());
            }
        }
    }

    let path = covers.join(format!("{key}.jpg"));
    if path.parent() != Some(covers) {
        return None;
    }
    let path_str = path.to_string_lossy().to_string();
    let already_valid = fs::metadata(&path)
        .map(|m| m.is_file() && m.len() > 0)
        .unwrap_or(false);
    if !already_valid {
        static COVER_TMP_SEQ: AtomicU64 = AtomicU64::new(0);
        let mut encoded_ok = false;
        if let Ok(decoded) = image::load_from_memory(bytes) {
            let resized = decoded.thumbnail(512, 512).to_rgb8();
            let seq = COVER_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
            let tmp_path = covers.join(format!("{key}.{seq}.tmp"));
            if let Ok(mut out_file) = fs::File::create(&tmp_path) {
                let mut encoder =
                    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out_file, 80);
                if encoder.encode_image(&resized).is_ok()
                    && fs::rename(&tmp_path, &path).is_ok()
                {
                    encoded_ok = true;
                } else {
                    let _ = fs::remove_file(&tmp_path);
                }
            }
        }
        // Fallback: if image crate cannot decode an exotic JPEG variant but bytes
        // are a valid small JPEG (starts with SOI 0xFF 0xD8 0xFF), write directly.
        if !encoded_ok
            && bytes.len() >= 3
            && bytes.len() <= 1024 * 1024
            && bytes[0] == 0xFF
            && bytes[1] == 0xD8
            && bytes[2] == 0xFF
        {
            let seq = COVER_TMP_SEQ.fetch_add(1, Ordering::Relaxed);
            let tmp_path = covers.join(format!("{key}.{seq}.tmp"));
            if fs::write(&tmp_path, bytes).is_ok() && fs::rename(&tmp_path, &path).is_ok() {
                encoded_ok = true;
            } else {
                let _ = fs::remove_file(&tmp_path);
            }
        }
        if !encoded_ok {
            return None;
        }
    }

    if let Some(cache_mutex) = cover_cache {
        if let Ok(mut cache) = cache_mutex.lock() {
            cache.insert(key, path_str.clone());
        }
    }
    Some(path_str)
}

pub fn should_count_play(position_ms: i64, duration_ms: Option<i64>) -> bool {
    let threshold_ms = match duration_ms {
        Some(d) if d > 0 => std::cmp::min(30_000, d / 2),
        _ => 30_000,
    };
    position_ms >= threshold_ms
}

pub fn record_play(db_path: String, track_id: i64) -> Result<(), String> {
    let conn = get_connection(&db_path)?;
    let now_ts = now();
    conn.execute(
        "INSERT INTO play_stats(track_id, play_count, last_played)
         VALUES (?1, 1, ?2)
         ON CONFLICT(track_id) DO UPDATE SET
             play_count = play_count + 1,
             last_played = excluded.last_played",
        params![track_id, now_ts],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn save_playback_state(
    db_path: String,
    queue_track_ids: Vec<i64>,
    current_index: i32,
    position_ms: i64,
) -> Result<(), String> {
    let conn = get_connection(&db_path)?;
    let json = serde_json::to_string(&queue_track_ids).map_err(|e| e.to_string())?;
    conn.execute(
        "INSERT INTO playback_state(id, queue_json, current_index, position_ms)
         VALUES(1, ?1, ?2, ?3)
         ON CONFLICT(id) DO UPDATE SET
             queue_json = excluded.queue_json,
             current_index = excluded.current_index,
             position_ms = excluded.position_ms",
        params![json, current_index, position_ms],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn load_playback_state(db_path: String) -> Result<Option<SavedPlaybackState>, String> {
    let conn = get_connection(&db_path)?;
    let res: Option<(String, i32, i64)> = conn
        .query_row(
            "SELECT queue_json, current_index, position_ms FROM playback_state WHERE id = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;

    if let Some((json, current_index, position_ms)) = res {
        let queue_track_ids: Vec<i64> = serde_json::from_str(&json).unwrap_or_default();
        Ok(Some(SavedPlaybackState {
            queue_track_ids,
            current_index,
            position_ms,
        }))
    } else {
        Ok(None)
    }
}

pub fn get_tracks_by_ids(db_path: String, ids: Vec<i64>) -> Result<Vec<Track>, String> {
    if ids.is_empty() {
        return Ok(Vec::new());
    }
    let conn = get_connection(&db_path)?;
    let ids_json = serde_json::to_string(&ids).map_err(|e| e.to_string())?;
    let sql = format!(
        "{TRACK_SELECT} JOIN json_each(?1) j ON t.id = j.value ORDER BY j.key"
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![ids_json], map_track)
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn toggle_favorite(db_path: String, track_id: i64) -> Result<bool, String> {
    let conn = get_connection(&db_path)?;
    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM favorites WHERE track_id = ?1",
            [track_id],
            |r| Ok(r.get::<_, i64>(0)? > 0),
        )
        .unwrap_or(false);

    if exists {
        conn.execute("DELETE FROM favorites WHERE track_id = ?1", [track_id])
            .map_err(|e| e.to_string())?;
        Ok(false)
    } else {
        conn.execute(
            "INSERT INTO favorites(track_id, added_at) VALUES (?1, ?2)",
            params![track_id, now()],
        )
        .map_err(|e| e.to_string())?;
        Ok(true)
    }
}

pub fn is_favorite(db_path: String, track_id: i64) -> Result<bool, String> {
    let conn = get_connection(&db_path)?;
    let exists: bool = conn
        .query_row(
            "SELECT COUNT(*) FROM favorites WHERE track_id = ?1",
            [track_id],
            |r| Ok(r.get::<_, i64>(0)? > 0),
        )
        .unwrap_or(false);
    Ok(exists)
}

pub fn add_tracks_to_favorites(db_path: String, track_ids: Vec<i64>) -> Result<u32, String> {
    let conn = get_connection(&db_path)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let ts = now();
    let mut added = 0;

    for tid in track_ids {
        let count: u32 = tx
            .query_row("SELECT COUNT(*) FROM favorites WHERE track_id = ?1", [tid], |r| r.get(0))
            .unwrap_or(0);

        if count == 0 {
            tx.execute(
                "INSERT INTO favorites(track_id, added_at) VALUES (?1, ?2)",
                params![tid, ts],
            )
            .map_err(|e| e.to_string())?;
            added += 1;
        }
    }

    tx.commit().map_err(|e| e.to_string())?;
    Ok(added)
}

pub fn list_favorite_tracks(db_path: String) -> Result<Vec<Track>, String> {
    let conn = get_connection(&db_path)?;
    let sql = format!(
        "{TRACK_SELECT} JOIN favorites f ON f.track_id = t.id WHERE t.unreadable = 0 ORDER BY f.added_at DESC"
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], map_track)
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn list_recently_played_tracks(db_path: String, limit: u32) -> Result<Vec<Track>, String> {
    let conn = get_connection(&db_path)?;
    let sql = format!(
        "{TRACK_SELECT} WHERE t.unreadable = 0 AND p.last_played IS NOT NULL ORDER BY p.last_played DESC LIMIT ?1"
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![limit], map_track)
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn list_most_played_tracks(db_path: String, limit: u32) -> Result<Vec<Track>, String> {
    let conn = get_connection(&db_path)?;
    let sql = format!(
        "{TRACK_SELECT} WHERE t.unreadable = 0 AND p.play_count > 0 ORDER BY p.play_count DESC, p.last_played DESC LIMIT ?1"
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![limit], map_track)
        .map_err(|e| e.to_string())?;
    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_create_schema_and_version() {
        let c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        let v: i32 = c
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);
        let cols: Vec<String> = c
            .prepare("PRAGMA table_info(tracks)")
            .unwrap()
            .query_map([], |r| r.get(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for required in [
            "path",
            "album_artist",
            "file_modified",
            "added_at",
            "unreadable",
            "search_text",
            "norm_artist",
            "norm_album",
        ] {
            assert!(cols.iter().any(|c| c == required), "Missing column {required}");
        }

        let tables: Vec<String> = c
            .prepare("SELECT name FROM sqlite_master WHERE type='table'")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert!(tables.contains(&"playback_state".to_string()));
    }

    #[test]
    fn corrupt_audio_fixture_is_kept_with_filename_metadata_and_hidden_from_search() {
        let root = std::env::temp_dir().join(format!("sonea-corrupt-{}", now()));
        std::fs::create_dir_all(&root).unwrap();
        let audio = root.join("Artist - broken.flac");
        std::fs::write(&audio, b"not a flac file").unwrap();
        let c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        assert!(index_file(&c, &audio, 123, &root).unwrap());
        let (title, artist, modified, unreadable): (String, Option<String>, i64, i64) = c
            .query_row(
                "SELECT title, artist, file_modified, unreadable FROM tracks",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap();
        assert_eq!(title, "Artist - broken");
        assert_eq!(artist, None);
        assert_eq!(modified, 123);
        assert_eq!(unreadable, 1);

        // Verify unreadable track is hidden from search
        let mut stmt = c.prepare(&format!("{TRACK_SELECT} WHERE t.unreadable = 0")).unwrap();
        let tracks: Vec<Track> = stmt.query_map([], map_track).unwrap().map(Result::unwrap).collect();
        assert_eq!(tracks.len(), 0);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn v1_to_v2_migration_on_populated_db() {
        let c = Connection::open_in_memory().unwrap();
        // Create schema v1 manually
        c.execute_batch(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                artist TEXT,
                album TEXT,
                album_artist TEXT,
                duration_ms INTEGER,
                track_no INTEGER,
                year INTEGER,
                format TEXT,
                bitrate INTEGER,
                sample_rate INTEGER,
                bit_depth INTEGER,
                channels INTEGER,
                cover_path TEXT,
                file_modified INTEGER NOT NULL,
                added_at INTEGER NOT NULL
            );
            CREATE TABLE favorites (track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE, added_at INTEGER NOT NULL);
            CREATE TABLE play_stats (track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE, play_count INTEGER NOT NULL DEFAULT 0, last_played INTEGER);
            PRAGMA user_version = 1;",
        )
        .unwrap();

        // Insert valid track
        c.execute(
            "INSERT INTO tracks (id, path, title, artist, album, duration_ms, file_modified, added_at)
             VALUES (1, '/music/cagri.flac', 'Çağrı', 'Sanatçı', 'Albüm', 240000, 1000, 1000);",
            [],
        )
        .unwrap();

        // Insert corrupt track (duration_ms is NULL)
        c.execute(
            "INSERT INTO tracks (id, path, title, artist, album, duration_ms, file_modified, added_at)
             VALUES (2, '/music/corrupt.wav', 'CorruptBackup', NULL, NULL, NULL, 1000, 1000);",
            [],
        )
        .unwrap();

        // Run migration
        migrate(&c).unwrap();

        let v: i32 = c
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // Check valid track
        let (unreadable_valid, search_text_valid): (i64, String) = c
            .query_row(
                "SELECT unreadable, search_text FROM tracks WHERE id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(unreadable_valid, 0);
        assert!(search_text_valid.contains("cagri"));
        assert!(search_text_valid.contains("sanatci"));

        // Check corrupt track
        let unreadable_corrupt: i64 = c
            .query_row("SELECT unreadable FROM tracks WHERE id = 2", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(unreadable_corrupt, 1);

        // Verify search queries against migrated DB
        let pat = format!("%{}%", normalize_for_search("ÇAĞRI"));
        let mut stmt = c
            .prepare(&format!(
                "{TRACK_SELECT} WHERE t.unreadable = 0 AND (?1 = '' OR t.search_text LIKE ?2)"
            ))
            .unwrap();
        let hits: Vec<Track> = stmt
            .query_map(params!["ÇAĞRI", pat], map_track)
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].title, "Çağrı");

        // Empty search returns only valid track (corrupt is hidden)
        let all_hits: Vec<Track> = stmt
            .query_map(params!["", "%"], map_track)
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(all_hits.len(), 1);
    }

    #[test]
    fn search_unicode_normalization_cases() {
        // Turkish: çağrı vs ÇAĞRI
        assert_eq!(normalize_for_search("çağrı"), normalize_for_search("ÇAĞRI"));
        assert_eq!(normalize_for_search("çağrı"), "cagri");

        // Turkish: İstanbul vs istanbul vs İSTANBUL
        assert_eq!(normalize_for_search("İstanbul"), normalize_for_search("istanbul"));
        assert_eq!(normalize_for_search("İSTANBUL"), normalize_for_search("istanbul"));
        assert_eq!(normalize_for_search("İstanbul"), "istanbul");

        // Cyrillic: Привет vs привет vs ПРИВЕТ
        assert_eq!(normalize_for_search("Привет"), normalize_for_search("привет"));
        assert_eq!(normalize_for_search("ПРИВЕТ"), normalize_for_search("привет"));
        assert_eq!(normalize_for_search("Привет"), "привет");

        // Japanese: Kanji and Katakana preserved
        assert_eq!(normalize_for_search("3分29秒"), "3分29秒");
        assert_eq!(normalize_for_search("ヒトリエ"), "ヒトリエ");
        assert_eq!(normalize_for_search("夜に駆ける"), "夜に駆ける");

        // Diacritics in Latin
        assert_eq!(normalize_for_search("Après-Midi"), "apres-midi");
        assert_eq!(normalize_for_search("Canción"), "cancion");
    }

    #[test]
    fn empty_scan_input_preserves_tracks_and_related_data() {
        let c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        c.execute(
            "INSERT INTO tracks(path,title,file_modified,added_at,unreadable) VALUES('track.flac','Track',42,1,0)",
            [],
        )
        .unwrap();
        c.execute("INSERT INTO favorites(track_id,added_at) VALUES(1,1)", [])
            .unwrap();
        c.execute(
            "INSERT INTO play_stats(track_id,play_count,last_played) VALUES(1,4,9)",
            [],
        )
        .unwrap();
        remove_missing_tracks(&c, &[]).unwrap();
        let counts: (i64, i64, i64) = c
            .query_row(
                "SELECT (SELECT count(*) FROM tracks),(SELECT count(*) FROM favorites),(SELECT count(*) FROM play_stats)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(counts, (1, 1, 1));
    }

    #[test]
    fn scanner_accepts_supported_audio_extensions() {
        assert!(is_audio(Path::new("song.FLAC")));
        assert!(is_audio(Path::new("song.m4a")));
        assert!(!is_audio(Path::new("corrupt.txt")));
    }

    #[test]
    fn test_should_count_play_rule() {
        // Track 120s: 50% = 60s, min(30s, 60s) = 30s
        assert!(!should_count_play(29_999, Some(120_000)));
        assert!(should_count_play(30_000, Some(120_000)));
        assert!(should_count_play(45_000, Some(120_000)));

        // Track 40s: 50% = 20s, min(30s, 20s) = 20s
        assert!(!should_count_play(19_999, Some(40_000)));
        assert!(should_count_play(20_000, Some(40_000)));
        assert!(should_count_play(25_000, Some(40_000)));

        // Track unknown or 0 duration: default 30s
        assert!(!should_count_play(29_999, None));
        assert!(should_count_play(30_000, None));
        assert!(!should_count_play(29_999, Some(0)));
        assert!(should_count_play(30_000, Some(0)));
    }

    #[test]
    fn test_record_play_updates_stats() {
        let c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        c.execute(
            "INSERT INTO tracks(id, path, title, file_modified, added_at, unreadable) VALUES(1, 'song.flac', 'Song', 1, 1, 0)",
            [],
        )
        .unwrap();

        // Initially no play stats
        let (play_count_initial, last_played_initial): (i64, Option<i64>) = c
            .query_row(
                "SELECT COALESCE(p.play_count, 0), p.last_played FROM tracks t LEFT JOIN play_stats p ON p.track_id = t.id WHERE t.id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(play_count_initial, 0);
        assert_eq!(last_played_initial, None);

        // Record 1 play
        c.execute(
            "INSERT INTO play_stats(track_id, play_count, last_played) VALUES(1, 1, 100)
             ON CONFLICT(track_id) DO UPDATE SET play_count = play_count + 1, last_played = excluded.last_played",
            [],
        )
        .unwrap();

        let (play_count1, last_played1): (i64, Option<i64>) = c
            .query_row(
                "SELECT play_count, last_played FROM play_stats WHERE track_id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(play_count1, 1);
        assert_eq!(last_played1, Some(100));

        // Record 2nd play
        c.execute(
            "INSERT INTO play_stats(track_id, play_count, last_played) VALUES(1, 1, 200)
             ON CONFLICT(track_id) DO UPDATE SET play_count = play_count + 1, last_played = excluded.last_played",
            [],
        )
        .unwrap();

        let (play_count2, last_played2): (i64, Option<i64>) = c
            .query_row(
                "SELECT play_count, last_played FROM play_stats WHERE track_id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(play_count2, 2);
        assert_eq!(last_played2, Some(200));
    }

    #[test]
    fn parse_year_handles_iso_and_invalid() {
        assert_eq!(parse_year_str("2024"), Some(2024));
        assert_eq!(parse_year_str("2024-05-12"), Some(2024));
        assert_eq!(parse_year_str("  1999/01/01 "), Some(1999));
        assert_eq!(parse_year_str("abcd"), None);
        assert_eq!(parse_year_str("99"), None);
    }

    #[test]
    fn incremental_scan_skips_unchanged_reindexes_modified_and_prunes_deleted() {
        let root = std::env::temp_dir().join(format!("sonea_inc_scan_{}", now()));
        let covers = root.join("covers");
        std::fs::create_dir_all(&covers).unwrap();
        let f1 = root.join("alpha.flac");
        let f2 = root.join("beta.mp3");
        std::fs::write(&f1, b"dummy audio 1").unwrap();
        std::fs::write(&f2, b"dummy audio 2").unwrap();

        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();

        let items1 = vec![
            MediaPath {
                path: f1.to_string_lossy().to_string(),
                file_modified: 1000,
            },
            MediaPath {
                path: f2.to_string_lossy().to_string(),
                file_modified: 2000,
            },
        ];

        let stats1 = run_incremental_scan(&conn, &covers, items1.clone(), |_| {}).unwrap();
        assert_eq!(stats1.indexed, 2);
        assert_eq!(stats1.skipped, 0);

        // Second scan with identical mtime & size must skip both without parsing.
        let stats2 = run_incremental_scan(&conn, &covers, items1, |_| {}).unwrap();
        assert_eq!(stats2.indexed, 0);
        assert_eq!(stats2.skipped, 2);

        // Modify file size of f1 and delete f2 -> f1 re-indexed, f2 removed from DB.
        std::fs::write(&f1, b"dummy audio 1 updated content longer").unwrap();
        std::fs::remove_file(&f2).unwrap();
        let items3 = vec![MediaPath {
            path: f1.to_string_lossy().to_string(),
            file_modified: 1000, // same mtime, different size
        }];
        let stats3 = run_incremental_scan(&conn, &covers, items3, |_| {}).unwrap();
        assert_eq!(stats3.indexed, 1);
        assert_eq!(stats3.skipped, 0);

        let remaining_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM tracks", [], |r| r.get(0))
            .unwrap();
        assert_eq!(remaining_count, 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cover_cache_deduplicates_identical_bytes_in_memory() {
        let root = std::env::temp_dir().join(format!("sonea_cover_dedup_{}", now()));
        std::fs::create_dir_all(&root).unwrap();

        // Build a valid tiny 2x2 PNG in memory.
        let img = image::RgbImage::from_pixel(2, 2, image::Rgb([125, 211, 252]));
        let mut png_bytes = Vec::new();
        {
            let mut cursor = std::io::Cursor::new(&mut png_bytes);
            image::DynamicImage::ImageRgb8(img)
                .write_to(&mut cursor, image::ImageFormat::Png)
                .unwrap();
        }

        let cache = Mutex::new(HashMap::new());
        let p1 = cache_cover_dedup(&png_bytes, &root, Some(&cache)).unwrap();
        let p2 = cache_cover_dedup(&png_bytes, &root, Some(&cache)).unwrap();
        assert_eq!(p1, p2);
        assert_eq!(cache.lock().unwrap().len(), 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn v6_to_v7_migration_is_idempotent_and_scans_valid_wav_audio() {
        let root = std::env::temp_dir().join(format!("sonea_v6_v7_{}", now()));
        let covers = root.join("covers");
        std::fs::create_dir_all(&covers).unwrap();

        // Create a valid 0.1s 44.1kHz mono 16-bit PCM WAV with uppercase .WAV extension.
        let wav_path = root.join("Test_Tone.WAV");
        let num_samples: u32 = 4410;
        let data_size: u32 = num_samples * 2;
        let riff_size: u32 = 36 + data_size;
        let mut wav = Vec::with_capacity((44 + data_size) as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&riff_size.to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes()); // PCM chunk size
        wav.extend_from_slice(&1u16.to_le_bytes()); // PCM format
        wav.extend_from_slice(&1u16.to_le_bytes()); // mono
        wav.extend_from_slice(&44100u32.to_le_bytes()); // sample rate
        wav.extend_from_slice(&(44100u32 * 2).to_le_bytes()); // byte rate
        wav.extend_from_slice(&2u16.to_le_bytes()); // block align
        wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_size.to_le_bytes());
        wav.resize((44 + data_size) as usize, 0u8);
        std::fs::write(&wav_path, &wav).unwrap();

        // Simulate a legacy v6 database without file_size column.
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                artist TEXT,
                album TEXT,
                album_artist TEXT,
                duration_ms INTEGER,
                track_no INTEGER,
                year INTEGER,
                format TEXT,
                bitrate INTEGER,
                sample_rate INTEGER,
                bit_depth INTEGER,
                channels INTEGER,
                cover_path TEXT,
                file_modified INTEGER NOT NULL,
                added_at INTEGER NOT NULL,
                unreadable INTEGER NOT NULL DEFAULT 0,
                search_text TEXT NOT NULL DEFAULT '',
                norm_artist TEXT NOT NULL DEFAULT '',
                norm_album TEXT NOT NULL DEFAULT '',
                replaygain_track_gain REAL,
                replaygain_album_gain REAL,
                replaygain_track_peak REAL
            );
            CREATE TABLE play_stats (track_id INTEGER PRIMARY KEY, play_count INTEGER NOT NULL DEFAULT 0, last_played INTEGER);
            PRAGMA user_version = 6;",
        )
        .unwrap();

        // Migrate v6 -> v7 and verify idempotency if re-run from version 6 with column present.
        migrate(&conn).unwrap();
        conn.pragma_update(None, "user_version", 6).unwrap();
        migrate(&conn).unwrap();
        let ver: i32 = conn.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
        assert_eq!(ver, SCHEMA_VERSION);

        let stats = run_incremental_scan(
            &conn,
            &covers,
            vec![MediaPath {
                path: wav_path.to_string_lossy().to_string(),
                file_modified: 5555,
            }],
            |_| {},
        )
        .unwrap();

        assert_eq!(stats.indexed, 1);
        assert_eq!(stats.unreadable, 0);

        let (format, dur, size): (Option<String>, Option<i64>, i64) = conn
            .query_row(
                "SELECT format, duration_ms, file_size FROM tracks LIMIT 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(format.as_deref(), Some("WAV"));
        assert!(dur.unwrap_or(0) > 0);
        assert_eq!(size, wav.len() as i64);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn cache_cover_dedup_resizes_rgba_png_to_max_512_jpeg() {
        let root = std::env::temp_dir().join(format!(
            "sonea_cover_test_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();

        // Build a synthetic 1024x1024 RGBA PNG image.
        let mut img = image::RgbaImage::new(1024, 1024);
        for (x, y, pixel) in img.enumerate_pixels_mut() {
            *pixel = image::Rgba([
                ((x * 255) / 1024) as u8,
                ((y * 255) / 1024) as u8,
                160,
                255,
            ]);
        }
        let mut png_bytes = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(img)
            .write_to(&mut png_bytes, image::ImageFormat::Png)
            .unwrap();
        let raw_png = png_bytes.into_inner();

        let saved_path = cache_cover_dedup(&raw_png, &root, None).expect("cover should be saved");
        let saved_meta = std::fs::metadata(&saved_path).unwrap();
        assert!(saved_meta.len() > 0 && saved_meta.len() < 120 * 1024);

        let decoded = image::open(&saved_path).unwrap();
        assert!(decoded.width() <= 512 && decoded.height() <= 512);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn incremental_scan_discovers_sidecar_cover_and_regenerates_when_deleted() {
        let root = std::env::temp_dir().join(format!(
            "sonea_sidecar_regen_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let album_dir = root.join("AlbumOne");
        let covers = root.join("covers");
        std::fs::create_dir_all(&album_dir).unwrap();
        std::fs::create_dir_all(&covers).unwrap();

        // Create a valid 0.1s WAV audio file + a sidecar cover.png in the same folder.
        let wav_path = album_dir.join("song.wav");
        let num_samples: u32 = 4410;
        let data_size: u32 = num_samples * 2;
        let riff_size: u32 = 36 + data_size;
        let mut wav = Vec::with_capacity((44 + data_size) as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&riff_size.to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&44100u32.to_le_bytes());
        wav.extend_from_slice(&88200u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_size.to_le_bytes());
        wav.resize((44 + data_size) as usize, 0);
        std::fs::write(&wav_path, &wav).unwrap();

        let cover_png_path = album_dir.join("cover.png");
        let img = image::RgbImage::from_pixel(640, 640, image::Rgb([30, 140, 210]));
        img.save(&cover_png_path).unwrap();

        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();

        let input = vec![MediaPath {
            path: wav_path.to_string_lossy().to_string(),
            file_modified: 9999,
        }];

        // Pass 1: discovers sidecar cover.png and caches resized JPEG.
        let stats1 = run_incremental_scan(&conn, &covers, input.clone(), |_| {}).unwrap();
        assert_eq!(stats1.indexed, 1);
        let cp1: Option<String> = conn
            .query_row("SELECT cover_path FROM tracks LIMIT 1", [], |r| r.get(0))
            .unwrap();
        let cp1 = cp1.expect("sidecar cover should be indexed");
        assert!(Path::new(&cp1).is_file());

        // Pass 2: unchanged file & intact cover -> skipped.
        let stats2 = run_incremental_scan(&conn, &covers, input.clone(), |_| {}).unwrap();
        assert_eq!(stats2.skipped, 1);
        assert_eq!(stats2.indexed, 0);

        // Pass 3: delete cached cover file -> incremental scan detects missing cover and regenerates it!
        std::fs::remove_file(&cp1).unwrap();
        assert!(!Path::new(&cp1).exists());
        let stats3 = run_incremental_scan(&conn, &covers, input, |_| {}).unwrap();
        assert_eq!(stats3.indexed, 1);
        assert_eq!(stats3.skipped, 0);
        assert!(Path::new(&cp1).is_file());
        assert!(std::fs::metadata(&cp1).unwrap().len() > 0);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn live_scan_emits_initial_and_intermediate_progress_before_finish() {
        let root = std::env::temp_dir().join(format!("sonea_live_progress_{}", now()));
        let covers = root.join("covers");
        std::fs::create_dir_all(&covers).unwrap();

        let mut items = Vec::new();
        for i in 0..8 {
            let p = root.join(format!("track_{i}.mp3"));
            std::fs::write(&p, b"not real mp3 data").unwrap();
            items.push(MediaPath {
                path: p.to_string_lossy().to_string(),
                file_modified: 1000 + i,
            });
        }

        let conn = Connection::open_in_memory().unwrap();
        migrate(&conn).unwrap();

        let mut events: Vec<ScanProgress> = Vec::new();
        let stats = run_incremental_scan(&conn, &covers, items, |ev| {
            events.push(ev);
        })
        .unwrap();

        assert_eq!(stats.total, 8);
        assert!(events.len() >= 3, "expected initial, intermediate, and final progress events");
        assert!(!events[0].finished);
        assert_eq!(events[0].total_count, 8);
        assert!(
            events.iter().any(|e| !e.finished && e.scanned_count > 0),
            "expected live non-zero scanned_count before finished"
        );
        let last = events.last().unwrap();
        assert!(last.finished);
        assert_eq!(last.processed, 8);
        assert_eq!(last.scanned_count, 8);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn validate_safe_file_path_rejects_traversal_nul_and_wrong_ext() {
        assert!(validate_safe_file_path("../secret.json", Some("json")).is_err());
        assert!(validate_safe_file_path("/tmp/a/../../etc/passwd", None).is_err());
        assert!(validate_safe_file_path("/tmp/bad\0name.json", Some("json")).is_err());
        assert!(validate_safe_file_path("/tmp/backup.txt", Some("json")).is_err());
        assert!(validate_safe_file_path("/tmp/sonea_backup.json", Some("json")).is_ok());
    }
}

