import 'dart:developer' as dev;

class DebugLogger {
  static void log(String message, {String tag = 'PocketServer'}) {
    dev.log('[$tag] $message');
  }

  static void error(String message, {String tag = 'PocketServer'}) {
    dev.log('[ERROR][$tag] $message');
  }

  static void warn(String message, {String tag = 'PocketServer'}) {
    dev.log('[WARN][$tag] $message');
  }
}