import 'package:flutter/foundation.dart';

/// Debug-only logger so release builds never leak user file paths,
/// library metadata, or raw exception stack traces to device logs.
void appLog(
  String tag,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  if (!kDebugMode) return;
  if (error != null && stackTrace != null) {
    debugPrint('[$tag] $message: $error\n$stackTrace');
  } else if (error != null) {
    debugPrint('[$tag] $message: $error');
  } else {
    debugPrint('[$tag] $message');
  }
}
