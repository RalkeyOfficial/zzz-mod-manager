import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/gamebanana/gb_failure.dart';

/// What either browser screen shows in place of content: an icon, a line saying
/// what happened, a line saying what to do about it, and — when there is
/// something to do — the control that does it.
///
/// One widget for both screens and for both kinds of nothing (a failure and an
/// empty result), because the grid and the detail view each had their own copy
/// of the error state and the two had already drifted apart: the grid printed a
/// detail line under the heading and the detail view did not.
class GbStateView extends StatelessWidget {
  const GbStateView({
    super.key,
    required this.icon,
    required this.title,
    this.iconColor,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String title;

  /// Defaults to the muted body colour. A failure passes `scheme.error`.
  final Color? iconColor;

  /// The second line: what the user can do, or what caused this. Optional —
  /// a state with nothing to add says nothing rather than padding itself.
  final String? hint;

  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Center(
      child: ConstrainedBox(
        // Bounded so the hint lines wrap at a readable measure rather than
        // running the width of a maximised window.
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: iconColor ?? scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall,
              ),
              if (hint case final hint?) ...[
                const SizedBox(height: 6),
                Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
              if (action case final action?) ...[
                const SizedBox(height: 16),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A failed request, rendered from [describeGbFailure]'s answer.
///
/// **Nothing from the wire is drawn.** `GbException.message` is server English
/// that cannot be localized and is marked "not for display" on the model itself;
/// the grid used to print it verbatim, so a back-off read as
/// `Server asked us to back off (HTTP 429)`. It goes to [debugPrint] instead,
/// which keeps the detail for a developer running from a terminal and keeps it
/// off the screen.
///
/// [onRetry] is injected rather than read from a provider, so the grid can
/// invalidate the results and the detail view its own profile, and so a test can
/// assert the press landed without standing up a container.
class GbFailureState extends StatelessWidget {
  const GbFailureState({
    super.key,
    required this.error,
    required this.onRetry,
  });

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final failure = describeGbFailure(error);

    debugPrint('GameBanana request failed (${failure.kind.name}): $error');

    // One exhaustive switch, so adding a kind fails to compile here — at the
    // only place that has to decide what it looks like. Both keys are spelled
    // out rather than built from a stem: `test/l10n_keys_test.dart` finds a key
    // by scanning `lib/` for single-quoted literals, and an interpolated one is
    // invisible to it.
    final (icon, titleKey, hintKey) = switch (failure.kind) {
      GbFailureKind.offline => (
          Icons.wifi_off,
          'marketplace.error_offline',
          'marketplace.error_offline_hint',
        ),
      GbFailureKind.rateLimited => (
          Icons.hourglass_empty,
          'marketplace.error_rate_limited',
          'marketplace.error_rate_limited_hint',
        ),
      GbFailureKind.notFound => (
          Icons.link_off,
          'marketplace.error_not_found',
          'marketplace.error_not_found_hint',
        ),
      GbFailureKind.generic => (
          Icons.error_outline,
          'marketplace.error_generic',
          'marketplace.error_generic_hint',
        ),
    };

    return GbStateView(
      icon: icon,
      iconColor: Theme.of(context).colorScheme.error,
      title: loc.t(titleKey),
      hint: loc.t(hintKey),
      // Absent, not disabled, on a failure that cannot come good: a greyed-out
      // button still says "this is the thing to press once you fix something",
      // and there is nothing to fix.
      action: failure.canRetry
          ? FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(loc.t('marketplace.retry')),
            )
          : null,
    );
  }
}
