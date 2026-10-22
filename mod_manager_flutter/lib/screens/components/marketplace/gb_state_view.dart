import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/gamebanana/gb_failure.dart';
import '../zenith_controls.dart';

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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
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

/// Hide installed dropped every mod there is to show, with Show installed, which turns it off. Browse and a creator's
/// page.
class GbAllInstalledState extends StatelessWidget {
  const GbAllInstalledState({super.key, required this.onShowInstalled});

  final VoidCallback onShowInstalled;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return GbStateView(
      icon: Icons.check_circle_outline,
      title: loc.t('marketplace.empty_all_installed'),
      action: OutlinedButton(
        style: smallButtonStyle(context),
        onPressed: onShowInstalled,
        child: Text(loc.t('marketplace.show_installed')),
      ),
    );
  }
}

/// The content filter dropped at least one mod and nothing is left; with [alsoInstalled], Hide installed dropped
/// the rest, and the title names both. Browse and a creator's page.
///
/// The action degrades `hide` to **`blur`**, never to `show` — the same rule the resolve dialog follows
/// (`docs/library-screen.md` §14). `blur` is the mode where the cards are on screen and each mod page can still be
/// opened, so it answers the complaint without turning a deliberate choice into its opposite. Only `hide` can
/// produce this state, so there is one transition to offer and no branch.
class GbAllFilteredState extends StatelessWidget {
  const GbAllFilteredState({super.key, required this.alsoInstalled, required this.onBlur});

  final bool alsoInstalled;
  final VoidCallback onBlur;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return GbStateView(
      icon: Icons.visibility_off_outlined,
      title: loc.t(alsoInstalled ? 'marketplace.empty_filtered_and_installed' : 'marketplace.empty_filtered'),
      action: FilledButton.icon(
        onPressed: onBlur,
        icon: const Icon(Icons.blur_on, size: 16),
        label: Text(loc.t('marketplace.empty_filtered_action')),
      ),
    );
  }
}

/// A failed request, rendered from [describeGbFailure]'s answer.
///
/// **Nothing from the wire is drawn.** `GbException.message` is server English
/// that cannot be localized and is marked "not for display" on the model itself.
/// The client logs the failed request with its detail; this widget shows only the kind.
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

    // **Not logged here.** This is a `build`, so it would write a line per
    // rebuild — and the client already logged the failure where it happened,
    // with the url and the status this never had.

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
      GbFailureKind.emptyResponse => (
          Icons.cloud_off,
          'marketplace.error_empty',
          'marketplace.error_empty_hint',
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
