import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonea/core/backup_validator.dart';
import 'package:sonea/settings/app_settings_controller.dart';

void main() {
  group('BackupValidator security & schema checks', () {
    test('accepts valid v1 library backup JSON', () {
      const valid = '''
      {
        "version": 1,
        "exported_at": 1700000000,
        "favorites": [{"path": "/music/a.flac", "title": "Song A", "artist": "Art", "added_at": 1}],
        "playlists": [{"name": "Mix", "track_paths": ["/music/a.flac"]}],
        "play_stats": [{"path": "/music/a.flac", "play_count": 3, "last_played": 1700000000}]
      }
      ''';
      final decoded = BackupValidator.validateLibraryBackupJsonString(valid);
      expect(decoded['version'], 1);
    });

    test('rejects unsupported schema version, non-object root, and malformed entries', () {
      expect(
        () => BackupValidator.validateLibraryBackupJsonString('[]'),
        throwsFormatException,
      );
      expect(
        () => BackupValidator.validateLibraryBackupJsonString(
          '{"version":2,"favorites":[],"playlists":[],"play_stats":[]}',
        ),
        throwsFormatException,
      );
      expect(
        () => BackupValidator.validateLibraryBackupJsonString(
          '{"version":1,"favorites":[{"path":123}],"playlists":[],"play_stats":[]}',
        ),
        throwsFormatException,
      );
    });

    test('rejects path traversal and empty backup files', () async {
      await expectLater(
        BackupValidator.validateLibraryBackupFile(File('../escape.json')),
        throwsFormatException,
      );

      final tmpDir = Directory.systemTemp.createTempSync('sonea_bkp_val_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));
      final emptyFile = File('${tmpDir.path}/empty.json')..writeAsStringSync('');
      await expectLater(
        BackupValidator.validateLibraryBackupFile(emptyFile),
        throwsFormatException,
      );
    });

    test('sanitizes companion settings JSON to strict allowlist', () {
      const raw = '''
      {
        "playbackSpeed": 1.25,
        "autoScanOnStartup": false,
        "injectedEvilKey": "rm -rf /",
        "__proto__": {"admin": true}
      }
      ''';
      final sanitized =
          BackupValidator.validateAndSanitizeSettingsJsonString(raw);
      expect(sanitized.keys, containsAll(['playbackSpeed', 'autoScanOnStartup']));
      expect(sanitized.containsKey('injectedEvilKey'), isFalse);
      expect(sanitized.containsKey('__proto__'), isFalse);
    });

    test('allowlist retains every key serialized by AppSettings.toJson()', () {
      final defaults = const AppSettings().toJson();
      final sanitized = BackupValidator.validateAndSanitizeSettingsJsonString(
        jsonEncode(defaults),
      );
      expect(sanitized.keys.toSet(), equals(defaults.keys.toSet()));
    });
  });
}
