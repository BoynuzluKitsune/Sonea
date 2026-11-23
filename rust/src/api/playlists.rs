use crate::api::library::{
    escape_like_pattern, get_connection, map_track, validate_safe_file_path, Track, TRACK_SELECT,
};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_PLAYLIST_IMPORT_BYTES: u64 = 5 * 1024 * 1024; // 5 MiB
const MAX_PLAYLIST_IMPORT_ENTRIES: usize = 10_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub track_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlaylistImportReport {
    pub playlist_id: i64,
    pub playlist_name: String,
    pub total_entries: u32,
    pub matched_count: u32,
    pub unmatched_entries: Vec<String>,
}

fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn sanitize_single_line(input: &str) -> String {
    input
        .chars()
        .filter(|&c| c != '\r' && c != '\n' && c != '\0')
        .collect()
}

pub fn create_playlist(db_path: String, name: String) -> Result<Playlist, String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("Playlist name cannot be empty".to_string());
    }
    if trimmed.len() > 200 {
        return Err("Playlist name is too long".to_string());
    }
    let conn = get_connection(&db_path)?;
    let ts = now();
    conn.execute(
        "INSERT INTO playlists(name, created_at, updated_at) VALUES(?1, ?2, ?3)",
        params![trimmed, ts, ts],
    )
    .map_err(|e| e.to_string())?;

    let id = conn.last_insert_rowid();
    Ok(Playlist {
        id,
        name: trimmed.to_string(),
        created_at: ts,
        updated_at: ts,
        track_count: 0,
    })
}

pub fn rename_playlist(
    db_path: String,
    playlist_id: i64,
    new_name: String,
) -> Result<(), String> {
    let trimmed = new_name.trim();
    if trimmed.is_empty() {
        return Err("Playlist name cannot be empty".to_string());
    }
    if trimmed.len() > 200 {
        return Err("Playlist name is too long".to_string());
    }
    let conn = get_connection(&db_path)?;
    let ts = now();
    conn.execute(
        "UPDATE playlists SET name = ?1, updated_at = ?2 WHERE id = ?3",
        params![trimmed, ts, playlist_id],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn delete_playlist(db_path: String, playlist_id: i64) -> Result<(), String> {
    let conn = get_connection(&db_path)?;
    conn.execute("DELETE FROM playlists WHERE id = ?1", [playlist_id])
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn list_playlists(db_path: String) -> Result<Vec<Playlist>, String> {
    let conn = get_connection(&db_path)?;
    let sql = "SELECT p.id, p.name, p.created_at, p.updated_at, (SELECT COUNT(*) FROM playlist_entries pe WHERE pe.playlist_id = p.id) FROM playlists p ORDER BY p.name COLLATE NOCASE";
    let mut stmt = conn.prepare(sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Playlist {
                id: r.get(0)?,
                name: r.get(1)?,
                created_at: r.get(2)?,
                updated_at: r.get(3)?,
                track_count: r.get(4)?,
            })
        })
        .map_err(|e| e.to_string())?;

    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn get_playlist_tracks(
    db_path: String,
    playlist_id: i64,
) -> Result<Vec<Track>, String> {
    let conn = get_connection(&db_path)?;
    let sql = format!(
        "{TRACK_SELECT} JOIN playlist_entries pe ON pe.track_id = t.id WHERE pe.playlist_id = ?1 ORDER BY pe.position ASC"
    );
    let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([playlist_id], map_track)
        .map_err(|e| e.to_string())?;

    rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
}

pub fn add_track_to_playlist(
    db_path: String,
    playlist_id: i64,
    track_id: i64,
) -> Result<(), String> {
    let conn = get_connection(&db_path)?;
    let max_pos: i64 = conn
        .query_row(
            "SELECT COALESCE(MAX(position), -1) FROM playlist_entries WHERE playlist_id = ?1",
            [playlist_id],
            |r| r.get(0),
        )
        .unwrap_or(-1);

    let next_pos = (max_pos + 1).max(0) as u32;

    conn.execute(
        "INSERT INTO playlist_entries(playlist_id, position, track_id) VALUES(?1, ?2, ?3)",
        params![playlist_id, next_pos, track_id],
    )
    .map_err(|e| e.to_string())?;

    conn.execute(
        "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
        params![now(), playlist_id],
    )
    .map_err(|e| e.to_string())?;

    Ok(())
}

pub fn add_tracks_to_playlist(
    db_path: String,
    playlist_id: i64,
    track_ids: Vec<i64>,
) -> Result<u32, String> {
    let conn = get_connection(&db_path)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;

    let mut max_pos: i64 = tx
        .query_row(
            "SELECT COALESCE(MAX(position), -1) FROM playlist_entries WHERE playlist_id = ?1",
            [playlist_id],
            |r| r.get(0),
        )
        .unwrap_or(-1);

    let existing: std::collections::HashSet<i64> = tx
        .prepare("SELECT track_id FROM playlist_entries WHERE playlist_id = ?1")
        .map_err(|e| e.to_string())?
        .query_map([playlist_id], |r| r.get(0))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();

    let mut added = 0;
    for tid in track_ids {
        if !existing.contains(&tid) {
            max_pos += 1;
            tx.execute(
                "INSERT INTO playlist_entries(playlist_id, position, track_id) VALUES(?1, ?2, ?3)",
                params![playlist_id, max_pos, tid],
            )
            .map_err(|e| e.to_string())?;
            added += 1;
        }
    }

    if added > 0 {
        tx.execute(
            "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
            params![now(), playlist_id],
        )
        .map_err(|e| e.to_string())?;
    }

    tx.commit().map_err(|e| e.to_string())?;
    Ok(added)
}

pub fn remove_track_from_playlist(
    db_path: String,
    playlist_id: i64,
    position: u32,
) -> Result<(), String> {
    let conn = get_connection(&db_path)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute(
        "DELETE FROM playlist_entries WHERE playlist_id = ?1 AND position = ?2",
        params![playlist_id, position],
    )
    .map_err(|e| e.to_string())?;
    tx.execute(
        "UPDATE playlist_entries SET position = position - 1 WHERE playlist_id = ?1 AND position > ?2",
        params![playlist_id, position],
    )
    .map_err(|e| e.to_string())?;
    tx.execute(
        "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
        params![now(), playlist_id],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;

    Ok(())
}

pub fn reorder_playlist_track(
    db_path: String,
    playlist_id: i64,
    old_index: u32,
    new_index: u32,
) -> Result<(), String> {
    if old_index == new_index {
        return Ok(());
    }
    let conn = get_connection(&db_path)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;

    let mut track_ids: Vec<i64> = {
        let mut stmt = tx
            .prepare(
                "SELECT track_id FROM playlist_entries WHERE playlist_id = ?1 ORDER BY position ASC",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([playlist_id], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?
    };

    let from = old_index as usize;
    let to = new_index as usize;
    if from >= track_ids.len() || to >= track_ids.len() {
        return Err("Reorder index out of bounds".to_string());
    }

    let moved = track_ids.remove(from);
    track_ids.insert(to, moved);

    tx.execute(
        "DELETE FROM playlist_entries WHERE playlist_id = ?1",
        [playlist_id],
    )
    .map_err(|e| e.to_string())?;

    {
        let mut stmt = tx
            .prepare(
                "INSERT INTO playlist_entries(playlist_id, position, track_id) VALUES(?1, ?2, ?3)",
            )
            .map_err(|e| e.to_string())?;
        for (pos, tid) in track_ids.into_iter().enumerate() {
            stmt.execute(params![playlist_id, pos as u32, tid])
                .map_err(|e| e.to_string())?;
        }
    }

    tx.execute(
        "UPDATE playlists SET updated_at = ?1 WHERE id = ?2",
        params![now(), playlist_id],
    )
    .map_err(|e| e.to_string())?;
    tx.commit().map_err(|e| e.to_string())?;
    Ok(())
}

pub fn import_playlist_file(
    db_path: String,
    file_path: String,
) -> Result<PlaylistImportReport, String> {
    let validated_path = validate_safe_file_path(&file_path, None)?;
    let meta = fs::symlink_metadata(&validated_path).map_err(|e| e.to_string())?;
    if !meta.file_type().is_file() {
        return Err("Playlist import path must be a regular file".to_string());
    }
    if meta.len() > MAX_PLAYLIST_IMPORT_BYTES {
        return Err("Playlist file exceeds 5MB limit".to_string());
    }

    let content = fs::read_to_string(&validated_path).map_err(|e| e.to_string())?;
    let stem = validated_path
        .file_stem()
        .and_then(|s| s.to_str())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("Imported Playlist");

    let mut total_entries = 0;
    let mut matched_count = 0;
    let mut unmatched_entries = Vec::new();
    let mut lines_to_process = Vec::new();

    // Parse format specific entries safely without panicking on malformed tags
    for line in content.lines() {
        if lines_to_process.len() >= MAX_PLAYLIST_IMPORT_ENTRIES {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        // PLS File1=...
        if trimmed.len() >= 5
            && trimmed.as_bytes()[..4].eq_ignore_ascii_case(b"file")
            && trimmed.contains('=')
        {
            if let Some((_, val)) = trimmed.split_once('=') {
                let candidate = val.trim();
                if !candidate.is_empty() {
                    lines_to_process.push(candidate.to_string());
                }
            }
        }
        // XSPF <location>...</location> (order-safe slice)
        else if let Some(start_idx) = trimmed.find("<location>") {
            let after_open = &trimmed[start_idx + "<location>".len()..];
            if let Some(rel_end) = after_open.find("</location>") {
                let loc = after_open[..rel_end].trim();
                let cleaned = loc.strip_prefix("file://").unwrap_or(loc);
                if !cleaned.is_empty() {
                    lines_to_process.push(cleaned.to_string());
                }
            }
        } else {
            lines_to_process.push(trimmed.to_string());
        }
    }

    let conn = get_connection(&db_path)?;
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    let ts = now();
    tx.execute(
        "INSERT INTO playlists(name, created_at, updated_at) VALUES(?1, ?2, ?3)",
        params![stem, ts, ts],
    )
    .map_err(|e| e.to_string())?;
    let playlist_id = tx.last_insert_rowid();

    let mut next_pos: u32 = 0;
    for entry in lines_to_process {
        total_entries += 1;

        let escaped_entry = escape_like_pattern(&entry);
        // Step 1: Exact path match
        let mut found_id: Option<i64> = tx
            .query_row(
                "SELECT id FROM tracks WHERE path = ?1 OR path LIKE ?2 ESCAPE '\\'",
                params![&entry, format!("%/{escaped_entry}")],
                |r| r.get(0),
            )
            .ok();

        // Step 2: Fallback to normalized title/filename search
        if found_id.is_none() {
            let filename = Path::new(&entry)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(&entry);
            let norm = escape_like_pattern(&crate::api::library::normalize_for_search(filename));
            if !norm.is_empty() {
                found_id = tx
                    .query_row(
                        "SELECT id FROM tracks WHERE search_text LIKE ?1 ESCAPE '\\' LIMIT 1",
                        params![format!("%{norm}%")],
                        |r| r.get(0),
                    )
                    .ok();
            }
        }

        if let Some(track_id) = found_id {
            tx.execute(
                "INSERT INTO playlist_entries(playlist_id, position, track_id) VALUES(?1, ?2, ?3)",
                params![playlist_id, next_pos, track_id],
            )
            .map_err(|e| e.to_string())?;
            next_pos = next_pos.saturating_add(1);
            matched_count += 1;
        } else {
            unmatched_entries.push(entry);
        }
    }

    tx.commit().map_err(|e| e.to_string())?;

    Ok(PlaylistImportReport {
        playlist_id,
        playlist_name: stem.to_string(),
        total_entries,
        matched_count,
        unmatched_entries,
    })
}

pub fn export_playlist_to_m3u8(
    db_path: String,
    playlist_id: i64,
    output_path: String,
) -> Result<(), String> {
    let out = validate_safe_file_path(&output_path, Some("m3u8"))?;
    if let Ok(meta) = fs::symlink_metadata(&out) {
        if meta.file_type().is_symlink() {
            return Err("Refusing to overwrite symlink playlist export target".to_string());
        }
    }
    let tracks = get_playlist_tracks(db_path, playlist_id)?;
    let mut m3u = String::from("#EXTM3U\n");
    for t in tracks {
        let dur = t.duration_ms.unwrap_or(0) / 1000;
        let artist = sanitize_single_line(t.artist.as_deref().unwrap_or("Unknown"));
        let title = sanitize_single_line(&t.title);
        let path = sanitize_single_line(&t.path);
        m3u.push_str(&format!("#EXTINF:{dur},{artist} - {title}\n{path}\n"));
    }

    fs::write(out, m3u).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_playlist_import_report() {
        let report = PlaylistImportReport {
            playlist_id: 1,
            playlist_name: "Test".to_string(),
            total_entries: 5,
            matched_count: 3,
            unmatched_entries: vec!["unmatched.mp3".to_string()],
        };
        assert_eq!(report.matched_count, 3);
        assert_eq!(report.unmatched_entries.len(), 1);
    }

    #[test]
    fn test_playlist_rejects_blank_names_compacts_and_reorders_positions() {
        let dir = std::env::temp_dir().join(format!("sonea_pl_test_{}", now()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("test.sqlite3").to_string_lossy().to_string();
        crate::api::library::initialize_database(db.clone()).unwrap();

        assert!(create_playlist(db.clone(), "   ".to_string()).is_err());
        let pl = create_playlist(db.clone(), "My Mix".to_string()).unwrap();
        assert!(rename_playlist(db.clone(), pl.id, "  ".to_string()).is_err());

        let conn = get_connection(&db).unwrap();
        conn.execute(
            "INSERT INTO tracks(id,path,title,file_modified,added_at) VALUES (1,'/a.flac','A',1,1),(2,'/b.flac','B',1,1),(3,'/c.flac','C',1,1)",
            [],
        )
        .unwrap();
        drop(conn);

        add_track_to_playlist(db.clone(), pl.id, 1).unwrap();
        add_track_to_playlist(db.clone(), pl.id, 2).unwrap();
        add_track_to_playlist(db.clone(), pl.id, 3).unwrap();

        reorder_playlist_track(db.clone(), pl.id, 2, 0).unwrap();
        let reordered = get_playlist_tracks(db.clone(), pl.id).unwrap();
        assert_eq!(
            reordered.iter().map(|t| t.id).collect::<Vec<_>>(),
            vec![3, 1, 2]
        );

        remove_track_from_playlist(db.clone(), pl.id, 0).unwrap();
        let remaining = get_playlist_tracks(db.clone(), pl.id).unwrap();
        assert_eq!(
            remaining.iter().map(|t| t.id).collect::<Vec<_>>(),
            vec![1, 2]
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_playlist_import_handles_malformed_xspf_and_rejects_traversal() {
        assert!(import_playlist_file(":memory:".to_string(), "../bad.m3u8".to_string()).is_err());

        let dir = std::env::temp_dir().join(format!("sonea_xspf_test_{}", now()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("test.db").to_string_lossy().to_string();
        crate::api::library::initialize_database(db.clone()).unwrap();

        let bad_xspf = dir.join("weird.xspf");
        fs::write(&bad_xspf, "</location><location>broken\n").unwrap();
        let report = import_playlist_file(db, bad_xspf.to_string_lossy().to_string()).unwrap();
        assert_eq!(report.total_entries, 0);

        let _ = std::fs::remove_dir_all(&dir);
    }
}
