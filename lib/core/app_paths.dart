import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sonea/core/app_logger.dart';

/// Centralized, cached filesystem paths for database and artwork cache.
class AppPaths {
  AppPaths._();

  static String? _supportDir;

  static Future<String> supportDir() async {
    final cached = _supportDir;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    _supportDir = dir.path;
    return dir.path;
  }

  static Future<String> databasePath() async {
    final base = await supportDir();
    return p.join(base, 'sonea.db');
  }

  static Future<String> cacheDir() async {
    final base = await supportDir();
    return p.join(base, 'cache');
  }

  static Future<String> coversDir() async {
    final cache = await cacheDir();
    return p.join(cache, 'covers');
  }

  static Future<String> playlistCoversDir() async {
    final base = await supportDir();
    final dirPath = p.join(base, 'playlist_covers');
    await Directory(dirPath).create(recursive: true);
    return dirPath;
  }

  /// App-owned backup directory safe under Android 11-15 Scoped Storage.
  static Future<String> backupsDir() async {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final dirPath = p.join(extDir.path, 'backups');
        await Directory(dirPath).create(recursive: true);
        return dirPath;
      }
    } catch (e) {
      appLog('AppPaths', 'External backups dir unavailable, using supportDir', e);
    }
    final base = await supportDir();
    final dirPath = p.join(base, 'backups');
    await Directory(dirPath).create(recursive: true);
    return dirPath;
  }

  /// Validates that an audio file path is non-empty and exists on disk.
  static Future<bool> fileExists(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    try {
      return await File(trimmed).exists();
    } catch (e) {
      appLog('AppPaths', 'fileExists check failed', e);
      return false;
    }
  }
}
