import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../utils/state_providers.dart';

/// Reads the library again whenever the window regains focus, so a mod added or an `.ini` edited outside the app
/// shows up on return (`docs/library-screen.md` §12). A scan that finds nothing changed keeps the list it has, and
/// one already running is joined rather than doubled. Draws nothing; `MainScreen` mounts it for as long as it lives.
class RescanOnWindowFocus extends ConsumerStatefulWidget {
  const RescanOnWindowFocus({super.key});

  @override
  ConsumerState<RescanOnWindowFocus> createState() => _RescanOnWindowFocusState();
}

class _RescanOnWindowFocusState extends ConsumerState<RescanOnWindowFocus> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() {
    unawaited(ref.read(libraryProvider.notifier).rescan());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
