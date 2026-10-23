import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ui/camera_list_screen.dart';
import '../ui/theme_controller.dart';
import 'session.dart';
import 'sign_in_screen.dart';

/// Viewer Mode's entry point: the camera list when signed in, the sign-in
/// screen otherwise. Rebuilds on every auth state change, so signing out
/// from the camera list (or a session expiring for good) lands back here.
class ViewerGate extends StatelessWidget {
  const ViewerGate({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, _) {
        final session = supabase.auth.currentSession;
        if (session == null) return const SignInScreen();
        // Keyed by user, so switching accounts tears down the previous
        // user's socket and roster instead of reusing them.
        return CameraListScreen(
          key: ValueKey(session.user.id),
          themeController: themeController,
        );
      },
    );
  }
}
