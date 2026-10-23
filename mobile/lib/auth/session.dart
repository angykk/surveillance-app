import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient get supabase => Supabase.instance.client;

/// The signed-in user's access token, refreshed first if it has already
/// expired (e.g. the app sat in the background past its lifetime, so
/// supabase_flutter's own auto-refresh never got to run). Null when signed
/// out or the refresh fails, which the server answers with a 401.
Future<String?> freshAccessToken() async {
  final session = supabase.auth.currentSession;
  if (session == null) return null;
  if (!session.isExpired) return session.accessToken;
  try {
    final refreshed = await supabase.auth.refreshSession();
    return refreshed.session?.accessToken;
  } on AuthException {
    return null;
  }
}

Future<Map<String, String>> userAuthHeaders() async {
  final token = await freshAccessToken();
  return token == null ? const {} : {'Authorization': 'Bearer $token'};
}
