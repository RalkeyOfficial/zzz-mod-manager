import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../l10n/app_localizations.dart';
import '../models/character_info.dart';
import 'gamebanana_url.dart';
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

/// **The page a mod folder points at**, or null when nothing about it names one.
///
/// Derived from the mod this folder is tracked against, which is the only thing
/// that knows. The link used to be a field of its own that the user typed and
/// nothing else read — a second answer to "which mod is this?", editable where
/// the answer that actually drives the update check was not. One answer now,
/// and every surface offering a link asks here.
///
/// The id is the **base** layer's — what the folder *is*. A patch written on top
/// modifies the mod, it does not change which mod page the folder belongs to.
String? modPageUrl(ModInfo mod) {
  final modId = mod.origin?.base?.modId;
  return modId == null ? null : gameBananaModUrl(modId);
}

/// Opens a mod's page in the default browser. Does nothing when there is none.
Future<void> openModLink(BuildContext context, ModInfo mod) async {
  final url = modPageUrl(mod);
  if (url == null) return;
  await launchExternalUrl(context, url);
}
