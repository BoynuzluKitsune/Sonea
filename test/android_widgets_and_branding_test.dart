import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final legacyBrand = String.fromCharCodes([109, 105, 117, 115, 105, 99]);

  group('Android 5-Widget Exact Count, Animations, Security & Sonea Branding', () {
    test('AndroidManifest registers strictly 5 Sonea widgets and security flags', () {
      final manifestFile = File('android/app/src/main/AndroidManifest.xml');
      expect(manifestFile.existsSync(), isTrue);
      final manifest = manifestFile.readAsStringSync();

      // Security hardening flags
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, contains('android:usesCleartextTraffic="false"'));

      // Exactly 5 AppWidget providers
      final updateMatches = RegExp(r'android\.appwidget\.action\.APPWIDGET_UPDATE')
          .allMatches(manifest)
          .length;
      final metaMatches = RegExp(r'android\.appwidget\.provider')
          .allMatches(manifest)
          .length;
      expect(updateMatches, 5);
      expect(metaMatches, 5);

      const expectedProviders = [
        '.widget.SoneaMicroPillWidget',
        '.widget.SoneaStudioCardWidget',
        '.widget.SoneaCoverTileWidget',
        '.widget.SoneaUpNextDeskWidget',
        '.widget.SoneaQuickMixDockWidget',
      ];
      for (final provider in expectedProviders) {
        expect(manifest, contains(provider));
      }

      // Zero legacy brand references in manifest
      expect(manifest.toLowerCase().contains(legacyBrand), isFalse);
    });

    test('All 5 widget layouts, info XMLs, ripples, and AVD/fallback animations exist', () {
      const requiredFiles = [
        'android/app/src/main/res/layout/sonea_widget_micro_pill.xml',
        'android/app/src/main/res/layout/sonea_widget_studio_card.xml',
        'android/app/src/main/res/layout/sonea_widget_cover_tile.xml',
        'android/app/src/main/res/layout/sonea_widget_up_next_desk.xml',
        'android/app/src/main/res/layout/sonea_widget_quick_mix_dock.xml',
        'android/app/src/main/res/xml/sonea_widget_micro_pill_info.xml',
        'android/app/src/main/res/xml/sonea_widget_studio_card_info.xml',
        'android/app/src/main/res/xml/sonea_widget_cover_tile_info.xml',
        'android/app/src/main/res/xml/sonea_widget_up_next_desk_info.xml',
        'android/app/src/main/res/xml/sonea_widget_quick_mix_dock_info.xml',
        'android/app/src/main/res/drawable/sonea_w_eq_avd.xml',
        'android/app/src/main/res/drawable/sonea_w_eq_static.xml',
        'android/app/src/main/res/drawable/sonea_w_eq_f0.xml',
        'android/app/src/main/res/drawable/sonea_w_eq_f1.xml',
        'android/app/src/main/res/drawable/sonea_w_eq_f2.xml',
        'android/app/src/main/res/drawable/sonea_w_eq_f3.xml',
        'android/app/src/main/res/drawable/sonea_w_ripple_circle.xml',
        'android/app/src/main/res/drawable/sonea_w_ripple_rounded.xml',
        'android/app/src/main/res/drawable/ic_stat_sonea.xml',
      ];
      for (final path in requiredFiles) {
        expect(File(path).existsSync(), isTrue, reason: 'Missing $path');
      }

      // Confirm strictly 5 provider XMLs in res/xml
      final xmlDir = Directory('android/app/src/main/res/xml');
      final providerXmls = xmlDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.xml'))
          .toList();
      expect(providerXmls.length, 5);
    });

    test('Core manifests and FFI bridge use pure sonea / rust_lib_sonea naming', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final cargo = File('rust/Cargo.toml').readAsStringSync();
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      final frb = File('lib/src/rust/frb_generated.dart').readAsStringSync();

      expect(pubspec, contains('name: sonea'));
      expect(pubspec, contains('rust_lib_sonea:'));
      expect(cargo, contains('name = "rust_lib_sonea"'));
      expect(gradle, contains('namespace = "com.sonea.app"'));
      expect(gradle, contains('applicationId = "com.sonea.app"'));
      expect(frb, contains("stem: 'rust_lib_sonea'"));

      for (final content in [pubspec, cargo, gradle, frb]) {
        expect(content.toLowerCase().contains(legacyBrand), isFalse);
      }
    });
  });
}
