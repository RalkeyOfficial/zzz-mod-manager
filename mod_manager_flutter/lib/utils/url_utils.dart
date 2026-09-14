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
/// Two different fields can answer this and only one of them is user-facing:
/// `source_url` is the link shown and edited on the mod, while the origin
/// block's `mod_id` is the machine handle the update check asks about. An
/// install fills both — the autofill writes the link, and the backfill derives
/// the id *from* it — so they normally agree.
///
/// The route that fills only one is the resolve dialog's search box: picking a
/// mod out of it records an id and never touches `source_url`. Without the
/// fallback that leaves a mod the app is checking for updates every time, on a
/// page it plainly knows, with no way to open it from anywhere in the app.
/// Deriving the link rather than writing one back is what fixes the mods
/// already in that state, and it keeps `source_url` the user's field.
///
/// The id is the **base** layer's — what the folder *is*. A patch written on top
/// modifies the mod, it does not change which mod page the folder belongs to.
String? modPageUrl(ModInfo mod) {
  final url = mod.sourceUrl?.trim();
  if (url != null && url.isNotEmpty) return url;
  final modId = mod.origin?.base?.modId;
  return modId == null ? null : gameBananaModUrl(modId);
}

/// Opens a mod's page in the default browser. Does nothing when there is none.
Future<void> openModLink(BuildContext context, ModInfo mod) async {
  final url = modPageUrl(mod);
  if (url == null) return;
  await launchExternalUrl(context, url);
}
