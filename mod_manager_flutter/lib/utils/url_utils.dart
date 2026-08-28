import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/character_info.dart';
import 'notifications.dart';

/// Opens [url] in the default external browser, validating the scheme and
/// reporting failures as notifications. Shared by the source-URL link and any
/// links embedded in a mod's markdown description.
Future<void> launchExternalUrl(BuildContext context, String url) async {
  final loc = context.loc;
  final notify = context.notify;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    // A warning rather than an error: nothing broke, the link is simply not one
    // we can open — which is a fact about the mod's own metadata.
    //
    // No portrait on either of these, though every caller holds a mod: what
    // failed is a fact about a URL string, and a character's face would claim
    // the message is about their mod.
    notify.warning(loc.t('mods.snackbar.invalid_url_title'), body: url);
    return;
  }
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    notify.error(loc.t('mods.errors.generic_title'), body: e.toString());
  }
}

/// Opens a mod's source URL in the default browser.
Future<void> openModLink(BuildContext context, ModInfo mod) async {
  final url = mod.sourceUrl;
  if (url == null || url.isEmpty) return;
  await launchExternalUrl(context, url);
}
