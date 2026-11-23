import 'dart:convert';
import 'dart:io';

/// Strict size, symlink, and schema validation for JSON backup & settings imports (CWE-20 / CWE-22 / CWE-770).
class BackupValidator {
  BackupValidator._();

  static const int maxLibraryBackupBytes = 10 * 1024 * 1024; // 10 MiB
  static const int maxSettingsBackupBytes = 256 * 1024; // 256 KiB
  static const int maxCollectionEntries = 50000;
  static const int maxPlaylists = 2000;

  /// Exact 1-to-1 allowlist matching `AppSettings.toJson()`.
  static const Set<String> allowedSettingsKeys = {
    'listDensity',
    'textScale',
    'coverCornerStyle',
    'nowPlayingBgEffect',
    'pauseOnNoisy',
    'interruptionBehavior',
    'skipSeconds',
    'playbackSpeed',
    'gaplessPlayback',
    'autoScanOnStartup',
    'autoFetchLyrics',
    'lyricsFontSize',
    'lyricsAlignment',
    'lyricsAutoScroll',
    'japaneseTransliteration',
  };

  static Future<void> _validateRegularFileBounds(
    File file, {
    required int maxBytes,
  }) async {
    if (file.path.contains('\u0000') || file.path.contains('..')) {
      throw const FormatException('Invalid backup file path.');
    }
    final entityType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (entityType != FileSystemEntityType.file) {
      throw const FormatException('Backup path must be a regular non-symlink file.');
    }
    final stat = await file.stat();
    if (stat.size <= 0 || stat.size > maxBytes) {
      throw FormatException(
        'Backup file size must be between 1 byte and ${maxBytes ~/ 1024} KB.',
      );
    }
  }

  /// Validates a library backup file's size, symlink safety, and JSON schema before Rust import.
  static Future<void> validateLibraryBackupFile(File file) async {
    await _validateRegularFileBounds(file, maxBytes: maxLibraryBackupBytes);
    final raw = await file.readAsString();
    validateLibraryBackupJsonString(raw);
  }

  /// Validates parsed library backup JSON structure.
  static Map<String, dynamic> validateLibraryBackupJsonString(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup root must be a JSON object.');
    }

    final version = decoded['version'];
    if (version is! int || version != 1) {
      throw FormatException('Unsupported backup version: $version');
    }

    final favorites = decoded['favorites'];
    final playlists = decoded['playlists'];
    final playStats = decoded['play_stats'];

    if (favorites is! List || playlists is! List || playStats is! List) {
      throw const FormatException(
        'Backup must contain favorites, playlists, and play_stats lists.',
      );
    }
    if (favorites.length > maxCollectionEntries ||
        playlists.length > maxPlaylists ||
        playStats.length > maxCollectionEntries) {
      throw const FormatException(
        'Backup exceeds maximum supported entry count.',
      );
    }

    for (final fav in favorites) {
      if (fav is! Map || fav['path'] is! String || fav['title'] is! String) {
        throw const FormatException('Invalid favorite entry in backup.');
      }
    }
    for (final pl in playlists) {
      if (pl is! Map || pl['name'] is! String || pl['track_paths'] is! List) {
        throw const FormatException('Invalid playlist entry in backup.');
      }
    }
    for (final ps in playStats) {
      if (ps is! Map || ps['path'] is! String || ps['play_count'] is! int) {
        throw const FormatException('Invalid play_stats entry in backup.');
      }
    }

    return decoded;
  }

  /// Validates and allowlist-filters companion settings JSON before applying to AppSettings.
  static Future<Map<String, dynamic>> validateAndSanitizeSettingsFile(
    File file,
  ) async {
    await _validateRegularFileBounds(file, maxBytes: maxSettingsBackupBytes);
    final raw = await file.readAsString();
    return validateAndSanitizeSettingsJsonString(raw);
  }

  static Map<String, dynamic> validateAndSanitizeSettingsJsonString(
    String rawJson,
  ) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Settings backup root must be a JSON object.');
    }
    final sanitized = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (allowedSettingsKeys.contains(entry.key)) {
        sanitized[entry.key] = entry.value;
      }
    }
    return sanitized;
  }
}
