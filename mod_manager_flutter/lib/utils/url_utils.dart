import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/character_info.dart';

/// Opens [url] in the default external browser, validating the scheme and
/// surfacing errors as snackbars. Shared by the source-URL link and any
/// links embedded in a mod's markdown description.
Future<void> launchExternalUrl(BuildContext context, String url) async {
  final loc = context.loc;
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(loc.t('mods.snackbar.invalid_url')),
        backgroundColor: Colors.orange,
      ),
    );
    return;
  }
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          loc.t('mods.errors.generic', params: {'message': e.toString()}),
        ),
        backgroundColor: Colors.red,
      ),
    );
  }
}

/// Opens a mod's source URL in the default browser.
Future<void> openModLink(BuildContext context, ModInfo mod) async {
  final url = mod.sourceUrl;
  if (url == null || url.isEmpty) return;
  await launchExternalUrl(context, url);
}
