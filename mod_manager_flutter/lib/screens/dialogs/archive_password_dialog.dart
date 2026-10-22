import 'package:flutter/material.dart';

import '../../core/palette.dart';
import '../../l10n/app_localizations.dart';
import '../components/zenith_controls.dart';

/// What the password dialog was answered with. Null from [showArchivePasswordDialog] is a dialog closed without an
/// answer, which leaves a waiting download waiting.
sealed class PasswordAnswer {
  const PasswordAnswer();
}

/// Install, with the password typed.
class PasswordGiven extends PasswordAnswer {
  const PasswordGiven(this.password);

  final String password;
}

/// Don't install.
class PasswordDeclined extends PasswordAnswer {
  const PasswordDeclined();
}

/// Open mod page, where the author usually puts the password. The download keeps waiting.
class PasswordOpenModPage extends PasswordAnswer {
  const PasswordOpenModPage();
}

/// Asks for an archive's password: [modName], one field, where authors usually put it, and Don't install beside
/// Install, which is disabled while the field is empty. Enter submits.
///
/// **The field shows what is typed.** The password is copied from a public mod description, and seeing a typo
/// matters more than hiding it. It is never stored: the answer is held in memory for the unpack it is given for.
///
/// [failed] says the last password did not open the archive. [offerModPage] adds the Open mod page link, which a
/// dropped archive has no page for.
Future<PasswordAnswer?> showArchivePasswordDialog(
  BuildContext context, {
  required String modName,
  bool failed = false,
  bool offerModPage = true,
}) =>
    showDialog<PasswordAnswer>(
      context: context,
      builder: (_) => ArchivePasswordDialog(modName: modName, failed: failed, offerModPage: offerModPage),
    );

class ArchivePasswordDialog extends StatefulWidget {
  const ArchivePasswordDialog({
    super.key,
    required this.modName,
    this.failed = false,
    this.offerModPage = true,
  });

  final String modName;
  final bool failed;
  final bool offerModPage;

  @override
  State<ArchivePasswordDialog> createState() => _ArchivePasswordDialogState();
}

class _ArchivePasswordDialogState extends State<ArchivePasswordDialog> {
  final TextEditingController _field = TextEditingController();

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    if (_field.text.isEmpty) return;
    Navigator.of(context).pop(PasswordGiven(_field.text));
  }

  @override
  Widget build(BuildContext context) {
    final loc = context.loc;
    final theme = Theme.of(context);
    final palette = ZenithPalette.of(context);
    return AlertDialog(
      title: Text(loc.t('downloads.password.title')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.modName, style: theme.textTheme.bodyMedium?.copyWith(color: palette.text2)),
            const SizedBox(height: 12),
            TextField(
              controller: _field,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: loc.t('downloads.password.field'),
                errorText: widget.failed ? loc.t('downloads.password.wrong') : null,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              loc.t('downloads.password.hint'),
              style: theme.textTheme.bodySmall?.copyWith(color: palette.text2),
            ),
            if (widget.offerModPage) ...[
              const SizedBox(height: 4),
              ZenithLink(
                loc.t('downloads.open_mod_page'),
                onTap: () => Navigator.of(context).pop(const PasswordOpenModPage()),
                style: theme.textTheme.bodySmall?.copyWith(color: palette.link),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(const PasswordDeclined()),
          child: Text(loc.t('downloads.dont_install')),
        ),
        FilledButton(
          onPressed: _field.text.isEmpty ? null : _submit,
          child: Text(loc.t('downloads.password.install')),
        ),
      ],
    );
  }
}
