use crate::api::library::{get_connection, validate_safe_file_path};
use serde::{Deserialize, Serialize};
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_BACKUP_FILE_BYTES: u64 = 10 * 1024 * 1024; // 10 MiB
const MAX_BACKUP_FAVORITES: usize = 50_000;
const MAX_BACKUP_PLAYLISTS: usize = 2_000;
const MAX_BACKUP_TRACKS_PER_PLAYLIST: usize = 20_000;
const MAX_BACKUP_PLAY_STATS: usize = 50_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FavoriteBackupItem {
    pub path: String,
    pub title: String,
    pub artist: Option<String>,
    pub added_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistBackupItem {
    pub name: String,
    pub track_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlayStatBackupItem {
    pub path: String,
    pub play_count: i64,
    pub last_played: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppBackupPayload {
    pub version: u32,
    pub exported_at: i64,
    pub favorites: Vec<FavoriteBackupItem>,
    pub playlists: Vec<PlaylistBackupItem>,
    pub play_stats: Vec<PlayStatBackupItem>,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

pub fn export_backup_json(
    db_path: String,
    output_file_path: String,
) -> Result<(), String> {
    let out_path = validate_safe_file_path(&output_file_path, Some("json"))?;
    let conn = get_connection(&db_path)?;

    // Favorites
    let mut fav_stmt = conn
        .prepare("SELECT t.path, t.title, t.artist, f.added_at FROM favorites f JOIN tracks t ON t.id = f.track_id")
        .map_err(|e| e.to_string())?;
    let fav_rows = fav_stmt
        .query_map([], |r| {
            Ok(FavoriteBackupItem {
                path: r.get(0)?,
                title: r.get(1)?,
                artist: r.get(2)?,
                added_at: r.get(3)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let favorites: Vec<FavoriteBackupItem> =
        fav_rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;

    // Playlists
    let mut pl_stmt = conn
        .prepare("SELECT id, name FROM playlists")
        .map_err(|e| e.to_string())?;
    let pl_rows = pl_stmt
        .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))
        .map_err(|e| e.to_string())?;

    let mut playlists = Vec::new();
    for pl_res in pl_rows {
        let (pl_id, pl_name) = pl_res.map_err(|e| e.to_string())?;
        let mut tr_stmt = conn
            .prepare("SELECT t.path FROM playlist_entries pe JOIN tracks t ON t.id = pe.track_id WHERE pe.playlist_id = ?1 ORDER BY pe.position")
            .map_err(|e| e.to_string())?;
        let tr_rows = tr_stmt
            .query_map([pl_id], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        let track_paths: Vec<String> =
            tr_rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;

        playlists.push(PlaylistBackupItem {
            name: pl_name,
            track_paths,
        });
    }

    // Play Stats
    let mut ps_stmt = conn
        .prepare("SELECT t.path, p.play_count, p.last_played FROM play_stats p JOIN tracks t ON t.id = p.track_id")
        .map_err(|e| e.to_string())?;
    let ps_rows = ps_stmt
        .query_map([], |r| {
            Ok(PlayStatBackupItem {
                path: r.get(0)?,
                play_count: r.get(1)?,
                last_played: r.get(2)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let play_stats: Vec<PlayStatBackupItem> =
        ps_rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;

    let payload = AppBackupPayload {
        version: 1,
        exported_at: now(),
        favorites,
        playlists,
        play_stats,
    };

    let json = serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())?;
    if let Ok(meta) = fs::symlink_metadata(&out_path) {
        if meta.file_type().is_symlink() {
            return Err("Refusing to overwrite symlink backup destination".to_string());
        }
    }
    let tmp_path = out_path.with_extension("json.tmp");
    if let Ok(meta) = fs::symlink_metadata(&tmp_path) {
        if meta.file_type().is_symlink() {
            return Err("Refusing to write to symlink temporary path".to_string());
        }
    }
    fs::write(&tmp_path, json).map_err(|e| e.to_string())?;
    if let Err(e) = fs::rename(&tmp_path, &out_path) {
        let _ = fs::remove_file(&tmp_path);
        return Err(e.to_string());
    }

    Ok(())
}

pub fn import_backup_json(
    db_path: String,
    input_file_path: String,
) -> Result<String, String> {
    let in_path = validate_safe_file_path(&input_file_path, Some("json"))?;
    let meta = fs::symlink_metadata(&in_path).map_err(|e| e.to_string())?;
    if !meta.file_type().is_file() {
        return Err("Backup path must be a regular file".to_string());
    }
    if meta.len() == 0 || meta.len() > MAX_BACKUP_FILE_BYTES {
        return Err("Backup file size is outside allowed bounds (1B..10MB)".to_string());
    }

    let json = fs::read_to_string(&in_path).map_err(|e| e.to_string())?;
    let payload: AppBackupPayload =
        serde_json::from_str(&json).map_err(|e| format!("Invalid backup JSON: {e}"))?;

    if payload.version != 1 {
        return Err(format!("Unsupported backup schema version: {}", payload.version));
    }
    if payload.favorites.len() > MAX_BACKUP_FAVORITES
        || payload.playlists.len() > MAX_BACKUP_PLAYLISTS
        || payload.play_stats.len() > MAX_BACKUP_PLAY_STATS
    {
        return Err("Backup payload exceeds maximum supported item count".to_string());
    }

    let conn = get_connection(&db_path)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;

    // Restore Favorites
    for fav in payload.favorites {
        if fav.path.trim().is_empty() || fav.path.contains('\0') {
            continue;
        }
        let track_id: Option<i64> = tx
            .query_row(
                "SELECT id FROM tracks WHERE path = ?1",
                [&fav.path],
                |r| r.get(0),
            )
            .ok();
        if let Some(id) = track_id {
            tx.execute(
                "INSERT INTO favorites(track_id, added_at) VALUES(?1, ?2) ON CONFLICT(track_id) DO NOTHING",
                rusqlite::params![id, fav.added_at],
            )
            .map_err(|e| e.to_string())?;
        }
    }

    // Restore Playlists
    for pl in payload.playlists {
        let clean_name = pl.name.trim();
        if clean_name.is_empty() || clean_name.len() > 200 {
            continue;
        }
        let ts = now();
        tx.execute(
            "INSERT INTO playlists(name, created_at, updated_at) VALUES(?1, ?2, ?3)",
            rusqlite::params![clean_name, ts, ts],
        )
        .map_err(|e| e.to_string())?;
        let pl_id = tx.last_insert_rowid();

        let mut pos: u32 = 0;
        for path in pl.track_paths.into_iter().take(MAX_BACKUP_TRACKS_PER_PLAYLIST) {
            if path.trim().is_empty() || path.contains('\0') {
                continue;
            }
            let track_id: Option<i64> = tx
                .query_row(
                    "SELECT id FROM tracks WHERE path = ?1",
                    [&path],
                    |r| r.get(0),
                )
                .ok();
            if let Some(id) = track_id {
                tx.execute(
                    "INSERT INTO playlist_entries(playlist_id, position, track_id) VALUES(?1, ?2, ?3) ON CONFLICT DO NOTHING",
                    rusqlite::params![pl_id, pos, id],
                )
                .map_err(|e| e.to_string())?;
                pos = pos.saturating_add(1);
            }
        }
    }

    // Restore Play Stats
    for ps in payload.play_stats {
        if ps.path.trim().is_empty() || ps.path.contains('\0') || ps.play_count < 0 {
            continue;
        }
        let track_id: Option<i64> = tx
            .query_row("SELECT id FROM tracks WHERE path = ?1", [&ps.path], |r| {
                r.get(0)
            })
            .ok();
        if let Some(id) = track_id {
            tx.execute(
                "INSERT INTO play_stats(track_id, play_count, last_played) VALUES(?1, ?2, ?3) ON CONFLICT(track_id) DO UPDATE SET play_count = max(play_stats.play_count, excluded.play_count)",
                rusqlite::params![id, ps.play_count, ps.last_played],
            )
            .map_err(|e| e.to_string())?;
        }
    }

    tx.commit().map_err(|e| e.to_string())?;
    Ok("Restore successful".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_backup_payload_serialize() {
        let payload = AppBackupPayload {
            version: 1,
            exported_at: 1000,
            favorites: vec![],
            playlists: vec![],
            play_stats: vec![],
        };
        let s = serde_json::to_string(&payload).unwrap();
        assert!(s.contains("\"version\":1"));
    }

    #[test]
    fn test_backup_rejects_path_traversal_and_bad_version() {
        assert!(import_backup_json(
            ":memory:".to_string(),
            "../evil/backup.json".to_string()
        )
        .is_err());
        assert!(export_backup_json(
            ":memory:".to_string(),
            "/tmp/a/../../evil.json".to_string()
        )
        .is_err());

        let tmp = std::env::temp_dir().join(format!("sonea_bad_ver_{}.json", now()));
        fs::write(
            &tmp,
            r#"{"version":99,"exported_at":1,"favorites":[],"playlists":[],"play_stats":[]}"#,
        )
        .unwrap();
        let res = import_backup_json(":memory:".to_string(), tmp.to_string_lossy().to_string());
        let _ = fs::remove_file(&tmp);
        assert!(res.is_err());
    }
}
