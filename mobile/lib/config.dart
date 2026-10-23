import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Values from `.env` (see `.env.example`), read in one place so a missing
/// key fails with a clear message instead of a bare null-check error.
class AppConfig {
  static String get serverUrl => _require('SERVER_IP');
  static String get supabaseUrl => _require('SUPABASE_URL');

  /// The Supabase publishable key (or a legacy anon key). It's designed to
  /// ship inside client apps — the server's own tables are locked down with
  /// RLS, and the app only uses Supabase for sign-in.
  static String get supabasePublishableKey => _require('SUPABASE_PUBLISHABLE_KEY');

  static String _require(String key) {
    final value = dotenv.env[key];
    if (value == null || value.isEmpty) {
      throw StateError('Missing $key in mobile/.env (see .env.example)');
    }
    return value;
  }
}
