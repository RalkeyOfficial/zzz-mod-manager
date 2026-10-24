import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/button_feedback.dart';
import '../../../core/button_working.dart';
import '../../../core/constants.dart';
import '../../../core/palette.dart';
import '../../../core/type_scale.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/app_update_service.dart';
import '../../../services/log/log_rotation.dart' show keptLogFiles;
import '../../../services/log/log_setup.dart';
import '../../../services/log/logger.dart';
import '../../../services/platform_service.dart';
import '../../../services/platform_service_factory.dart';
import '../../../utils/home_relative.dart';
import '../../../utils/notifications.dart';
import '../../../utils/relative_age.dart';
import '../../../utils/state_providers.dart';
import '../zenith_controls.dart';
import '../zenith_switch.dart';
import 'settings_widgets.dart';

/// Persists the log-file setting. Production is [ApiService].
typedef LogSettingWriter = Future<void> Function(bool enabled);

/// Builds the text that goes on the clipboard.
typedef DiagnosticsBuilder = String Function();

/// Puts text on the clipboard. Production is Flutter's own [Clipboard].
typedef ClipboardWriter = Future<void> Function(String text);

/// Settings > About: what the app is, whether a newer release exists, where its source and issues are, and what to
/// attach to a bug report (`docs/app-updates.md`, `docs/logging.md` §9).
///
/// Each seam stands in for something a widget test must not touch: the platform opens browsers and file managers,
/// [ApiService] writes the developer's real `config.json`, and the clipboard is shared with the machine.
class AboutSection extends ConsumerWidget {
  const AboutSection({super.key, this.platform, this.writer, this.buildDiagnostics, this.writeClipboard});

  final PlatformService? platform;
  final LogSettingWriter? writer;
  final DiagnosticsBuilder? buildDiagnostics;
  final ClipboardWriter? writeClipboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = this.platform ?? PlatformServiceFactory.getInstance();
    final palette = ZenithPalette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 24,
      children: [
        _Hero(platform: platform),
        _LinkCards(platform: platform),
        _BugReports(
          platform: platform,
          writer: writer,
          buildDiagnostics: buildDiagnostics,
          writeClipboard: writeClipboard,
        ),
        Text(
          context.loc.t('about.disclaimer'),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: palette.text3, height: 1.6),
        ),
      ],
    );
  }
}

/// Opens [url] in the browser, and says so when it did not open.
Future<void> _openUrl(BuildContext context, PlatformService platform, String url) async {
  final loc = context.loc;
  final notify = context.notify;
  if (!await platform.openUrlInBrowser(url)) notify.error(loc.t('about.links.open_failed'), body: url);
}

/// The width of [text] set in [style], to tell whether a button still fits beside its neighbour.
double _textWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// The hero card: the logo, the name and version, the update line, and the two buttons.
///
/// The canvas lays them out as a wrapping flex row: the text takes a 280px basis and the buttons drop under the
/// logo and text, then the text drops under the logo, as the card narrows.
class _Hero extends ConsumerWidget {
  const _Hero({required this.platform});

  static const double _logo = 120;
  static const double _gap = 28;
  static const double _textBasis = 280;

  final PlatformService platform;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final labelLarge = Theme.of(context).textTheme.labelLarge;
    final result = ref.watch(appUpdateResultProvider);
    // The check button: 14px of padding either side, a 16px icon and the 8px between it and the label.
    final buttonsWidth = 28 + 16 + 8 + _textWidth(context, loc.t('about.check'), labelLarge);

    // A Container, not a DecoratedBox around a clip: the border insets its child as CSS border-box does, so the ground
    // does not paint over it.
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.outline),
      ),
      child: DottedGround(
        ground: ElementGround(palette.field, palette.rowSelected, palette.outline),
        spacing: 12,
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final text = _HeroText(platform: platform, result: result);
              final buttons = _HeroButtons(platform: platform, result: result);
              const logo = _Logo(size: _logo);
              if (width >= _logo + _gap + _textBasis + _gap + buttonsWidth) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  spacing: _gap,
                  children: [logo, Expanded(child: text), buttons],
                );
              }
              if (width >= _logo + _gap + _textBasis) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: _gap,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      spacing: _gap,
                      children: [logo, Expanded(child: text)],
                    ),
                    buttons,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: _gap,
                children: [
                  logo,
                  SizedBox(width: double.infinity, child: text),
                  buttons,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The logo with the canvas's drop shadow: 14px down, 32px of blur, half-opaque black.
class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = ZenithPalette.of(context);
    final asset = palette.brightness == Brightness.dark
        ? 'assets/brand/logo-mark-on-dark.png'
        : 'assets/brand/logo-mark-on-light.png';
    Image mark({String? label}) => Image.asset(
      asset,
      width: size,
      height: size,
      filterQuality: FilterQuality.medium,
      semanticLabel: label,
    );
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ExcludeSemantics(
            child: Transform.translate(
              offset: const Offset(0, 14),
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16, tileMode: TileMode.decal),
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(palette.downloadsShadow, BlendMode.srcIn),
                  child: mark(),
                ),
              ),
            ),
          ),
          mark(label: context.loc.t('about.logo_label')),
        ],
      ),
    );
  }
}

class _HeroText extends StatelessWidget {
  const _HeroText({required this.platform, required this.result});

  final PlatformService platform;
  final AppUpdateResult? result;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);
    // The version is 13px mono, the body size in the mono face.
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: kMonoFont, color: palette.text);

    final version = loc.t(
      'about.version',
      params: {'version': AppConstants.appVersion, 'platform': platform.platformName},
    );
    final at = version.indexOf(AppConstants.appVersion);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        Text(loc.t('app.wordmark'), style: theme.textTheme.displaySmall?.copyWith(color: palette.text)),
        Text(loc.t('about.tagline'), style: theme.textTheme.bodyMedium?.copyWith(color: palette.textProse)),
        Text.rich(
          TextSpan(
            style: theme.textTheme.bodyMedium?.copyWith(color: palette.text2),
            children: at < 0
                ? [TextSpan(text: version)]
                : [
                    TextSpan(text: version.substring(0, at)),
                    TextSpan(text: AppConstants.appVersion, style: mono),
                    TextSpan(text: version.substring(at + AppConstants.appVersion.length)),
                  ],
          ),
        ),
        if (result case final result?) Semantics(liveRegion: true, child: _UpdateLine(result: result)),
      ],
    );
  }
}

/// A line with a 14px icon and 12px text, 8px apart: the canvas's "You're on the latest version" line.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.iconColor, required this.text, required this.textColor});

  final IconData icon;
  final Color iconColor;
  final String text;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        Icon(icon, size: 14, color: iconColor),
        Flexible(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: textColor))),
      ],
    );
  }
}

/// What the last check found, in one line.
class _UpdateLine extends StatelessWidget {
  const _UpdateLine({required this.result});

  final AppUpdateResult result;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final age = relativeAgeLabel(loc, result.checkedAt, DateTime.now());
    switch (result.outcome) {
      case AppUpdateOutcome.upToDate:
        return _StatusLine(
          icon: Icons.check_rounded,
          iconColor: palette.accent,
          // `releases/latest` hides pre-releases, so a pre-release build cannot be told it is on the latest version.
          text: loc.t(
            result.runningPreRelease ? 'about.update.latest_stable' : 'about.update.latest',
            params: {'age': age},
          ),
          textColor: palette.textProse,
        );
      case AppUpdateOutcome.newer:
        return _StatusLine(
          icon: Icons.arrow_circle_up_rounded,
          iconColor: palette.accent,
          text: loc.t('about.update.newer', params: {'version': result.latest ?? '', 'age': age}),
          textColor: palette.textProse,
        );
      case AppUpdateOutcome.failed:
        return _StatusLine(
          icon: Icons.warning_amber_rounded,
          iconColor: palette.amber,
          text: loc.t(switch (result.failure) {
            AppUpdateFailure.rateLimited => 'about.update.rate_limited',
            AppUpdateFailure.noRelease => 'about.update.no_release',
            AppUpdateFailure.unreadable => 'about.update.unreadable',
            AppUpdateFailure.offline || null => 'about.update.offline',
          }),
          textColor: palette.amber,
        );
    }
  }
}

class _HeroButtons extends StatelessWidget {
  const _HeroButtons({required this.platform, required this.result});

  final PlatformService platform;
  final AppUpdateResult? result;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          WorkingAction(
            onPressed: (work) => _check(context, work),
            builder: (context, onPressed) => OutlinedButton.icon(
              onPressed: onPressed,
              icon: const WorkingIcon(Icon(Icons.sync_rounded)),
              label: Text(loc.t('about.check')),
            ),
          ),
          TextButton(
            // The newest release's own page when the check found one, otherwise the list of releases.
            onPressed: () => _openUrl(context, platform, result?.releaseUrl ?? '${AppConstants.repositoryUrl}/releases'),
            child: Text(loc.t('about.release_notes')),
          ),
        ],
      ),
    );
  }

  /// Held by the app's container rather than this widget's ref: leaving Settings mid-check disposes the widget, and
  /// the answer is still wanted when the user comes back.
  Future<void> _check(BuildContext context, WorkSpan work) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final service = container.read(appUpdateServiceProvider);
    final result = await work(service.check);
    container.read(appUpdateResultProvider.notifier).state = result;
  }
}

/// Source code, Report a problem and License: three cards in a row, stacked when the page is narrow.
class _LinkCards extends StatelessWidget {
  const _LinkCards({required this.platform});

  /// The canvas always draws three columns; below this width they would be too narrow to hold a title and its hint.
  static const double _stackBelow = 560;

  final PlatformService platform;

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final cards = [
      _LinkCard(
        icon: Icons.code_rounded,
        title: loc.t('about.links.source'),
        hint: loc.t('about.links.source_hint'),
        onTap: () => _openUrl(context, platform, AppConstants.repositoryUrl),
      ),
      _LinkCard(
        icon: Icons.warning_amber_rounded,
        title: loc.t('about.links.report'),
        hint: loc.t('about.links.report_hint'),
        onTap: () => _openUrl(context, platform, '${AppConstants.repositoryUrl}/issues/new'),
      ),
      _LinkCard(
        icon: Icons.description_outlined,
        title: loc.t('about.links.license'),
        hint: loc.t('about.links.license_name'),
        onTap: () => _openUrl(context, platform, AppConstants.repositoryUrl),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _stackBelow) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 12, children: cards);
        }
        // Equal heights even when one card's text wraps; the page scrolls, so the height has no bound to stretch to.
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [for (final card in cards) Expanded(child: card)],
          ),
        );
      },
    );
  }
}

/// A card that opens a link. Under the pointer its border goes from `outline` to `edge`, as the canvas's `.lk:hover`.
class _LinkCard extends StatefulWidget {
  const _LinkCard({required this.icon, required this.title, required this.hint, required this.onTap});

  final IconData icon;
  final String title;
  final String hint;
  final VoidCallback onTap;

  @override
  State<_LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends State<_LinkCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: _hovered ? palette.edge : palette.outline),
    );
    return Semantics(
      link: true,
      label: '${widget.title}, ${widget.hint}',
      excludeSemantics: true,
      onTap: widget.onTap,
      child: KeyboardFocusRing(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Material(
          color: palette.field,
          shape: shape,
          child: InkWell(
            customBorder: shape,
            hoverColor: Colors.transparent,
            onHover: (hovered) => setState(() => _hovered = hovered),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                spacing: 12,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(color: palette.raised, borderRadius: BorderRadius.circular(9)),
                    child: SizedBox.square(
                      dimension: 34,
                      child: Icon(widget.icon, size: 16, color: palette.text2),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: palette.text),
                        ),
                        Text(widget.hint, style: theme.textTheme.bodySmall?.copyWith(color: palette.text3)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What to attach to a bug report: where the app keeps its data and logs, the system summary that copies out, and
/// whether it writes a log.
class _BugReports extends ConsumerWidget {
  /// The canvas's About row gives its text a 260px basis, where Settings' rows have 280.
  static const double _textBasis = 260;

  const _BugReports({required this.platform, this.writer, this.buildDiagnostics, this.writeClipboard});

  final PlatformService platform;
  final LogSettingWriter? writer;
  final DiagnosticsBuilder? buildDiagnostics;
  final ClipboardWriter? writeClipboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final palette = ZenithPalette.of(context);
    final logging = ref.watch(fileLoggingProvider);
    final appData = platform.getAppDataPath();
    final open = loc.t('about.bug_reports.open');
    final openLogs = loc.t('about.bug_reports.open_logs');
    final copy = loc.t('about.bug_reports.copy');

    return SettingsSectionBlock(
      title: loc.t('about.bug_reports.title'),
      children: [
        SettingsRow(
          dense: true,
          minTextWidth: _textBasis,
          label: loc.t('about.bug_reports.app_data'),
          description: null,
          detail: SettingsValue(homeRelative(appData, home: platform.homeDirectoryPath), top: 0),
          trailing: OutlinedButton(
            style: smallButtonStyle(context),
            onPressed: () => _openFolder(context, appData, hintKey: 'about.bug_reports.open_failed_app_data_hint'),
            child: Text(open),
          ),
        ),
        SettingsRow(
          dense: true,
          minTextWidth: _textBasis,
          label: loc.t('about.bug_reports.logs'),
          description: loc.plural(
            'about.bug_reports.logs_hint',
            keptLogFiles,
            params: {'count': '$keptLogFiles'},
          ),
          trailing: OutlinedButton(
            style: smallButtonStyle(context),
            // The folder rather than a file: the run that broke is picked out of all that are kept.
            onPressed: () => _openFolder(context, Log.logsDirectory, hintKey: 'about.bug_reports.open_failed_logs_hint'),
            child: Text(openLogs),
          ),
        ),
        SettingsRow(
          dense: true,
          minTextWidth: _textBasis,
          label: loc.t('about.bug_reports.system_info'),
          description: null,
          detail: SettingsValue(_summary(context, ref), top: 0, color: palette.text3),
          trailing: OutlinedButton.icon(
            style: smallButtonStyle(context),
            onPressed: () => _copy(context),
            icon: const Icon(Icons.content_copy_rounded),
            label: Text(copy),
          ),
        ),
        SettingsRow(
          dense: true,
          minTextWidth: _textBasis,
          label: loc.t('about.bug_reports.write_log'),
          description: loc.t('about.bug_reports.write_log_hint'),
          trailing: ZenithSwitch(
            value: logging,
            semanticLabel: loc.t('about.bug_reports.write_log'),
            onChanged: (value) {
              // The provider first so the switch moves this frame, then the write.
              ref.read(fileLoggingProvider.notifier).state = value;
              (writer ?? ApiService.setFileLogging)(value);
            },
          ),
        ),
      ],
    );
  }

  /// "2.2.2 · Linux · ZZMI found · 61 mods", leaving out what is not known yet.
  String _summary(BuildContext context, WidgetRef ref) {
    final loc = context.loc;
    final zzmi = ref.watch(zzmiFoundProvider).valueOrNull;
    final mods = ref.watch(libraryProvider).valueOrNull?.length;
    return [
      AppConstants.appVersion,
      platform.platformName,
      if (zzmi != null) loc.t(zzmi ? 'about.bug_reports.zzmi_found' : 'about.bug_reports.zzmi_missing'),
      if (mods != null) loc.plural('about.bug_reports.mods', mods, params: {'count': '$mods'}),
    ].join(' · ');
  }

  /// Opens [path] in the file manager. [hintKey] names the likely reasons for this folder when it does not open.
  Future<void> _openFolder(BuildContext context, String path, {required String hintKey}) async {
    final loc = context.loc;
    final notify = context.notify;
    if (await platform.openFolderInFileManager(path)) return;
    // Only the failure is reported: a file manager that opened is its own confirmation.
    notify.error(
      loc.t('about.bug_reports.open_failed'),
      body: loc.t(hintKey, params: {'path': homeRelative(path, home: platform.homeDirectoryPath)}),
    );
  }

  Future<void> _copy(BuildContext context) async {
    final loc = context.loc;
    final notify = context.notify;
    final write = writeClipboard ?? (String text) => Clipboard.setData(ClipboardData(text: text));
    // From the log's in-memory lines rather than the file: it works with the file switched off, and they are already
    // redacted.
    await write((buildDiagnostics ?? diagnosticsText)());
    notify.done(loc.t('about.bug_reports.copied_title'), body: loc.t('about.bug_reports.copied_body'));
  }
}
