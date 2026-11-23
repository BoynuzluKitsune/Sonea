import 'dart:ui' as ui;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sonea/core/app_logger.dart';
import 'package:sonea/settings/app_settings_controller.dart';
import 'package:sonea/src/rust/frb_generated.dart';
import 'package:sonea/theme/theme_controller.dart';
import 'package:sonea/ui/navigation/main_navigation_shell.dart';
import 'package:sonea/ui/onboarding/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Gracefully catch offline Google Fonts download failures so the app never
  // crashes without internet and seamlessly falls back to bundled local fonts.
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    final msg = error.toString();
    if (msg.contains('google_fonts') ||
        msg.contains('fonts.gstatic.com') ||
        msg.contains('Failed to load font')) {
      appLog('Fonts', 'Offline font fallback active: $msg');
      return true;
    }
    appLog('Uncaught', 'Unhandled async error', error, stack);
    return false;
  };

  // Bound decoded image cache to keep RAM lean across large artwork libraries.
  PaintingBinding.instance.imageCache
    ..maximumSize = 200
    ..maximumSizeBytes = 64 << 20; // 64 MiB

  await RustLib.init();
  runApp(const ProviderScope(child: SoneaApp()));
}

class SoneaApp extends ConsumerWidget {
  const SoneaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeTokens = ref.watch(themeControllerProvider);
    final textScaleFactor = ref.watch(
      appSettingsProvider.select((s) => s.textScaleFactor),
    );
    final showOnboarding = ref.watch(
      appSettingsProvider.select((s) => s.isLoaded && !s.hasCompletedOnboarding),
    );

    // Keep MaterialApp key stable across theme & brightness changes to avoid
    // InheritedWidget _dependents.isEmpty lifecycle assertions, and disable
    // 200ms frame-by-frame theme Color.lerp animation for instant 60 FPS switching.
    return MaterialApp(
      title: 'Sonea',
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: Duration.zero,
      theme: themeTokens.toThemeDataFor(Brightness.light),
      darkTheme: themeTokens.toThemeDataFor(Brightness.dark),
      themeMode: themeTokens.themeMode,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(textScaleFactor),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: showOnboarding
          ? const OnboardingScreen()
          : const MainNavigationShell(),
    );
  }
}
