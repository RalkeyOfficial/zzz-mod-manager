/// `_aRequirements` — what the author says their mod needs to work.
///
/// The site labels it *"Dependencies and prerequisites required to use this
/// Mod"*, and each entry is a free-text label with an optional link. The label
/// is whatever the author typed, so it is a **string to show, never a string to
/// match on**; only the link carries anything machine-readable, and only when it
/// points at a GameBanana mod page.
///
/// ## What it is good for, and the measured limit
///
/// For a patch this is occasionally the answer to *"which mod does this patch?"*
/// stated by the person who would know. Measured over ZZZ (see
/// `docs/patch-destinations.md`):
///
/// - **18%** of patch-sized mods declare any requirement, and **9%** link a
///   GameBanana mod page;
/// - of six such links, **four named the mod being patched** and two named a
///   shared prerequisite (a normal-map fix) that is not a base mod at all;
/// - across ZZZ mods generally, every mod link in the sample pointed at one
///   shader tool.
///
/// So a mod link is **evidence worth putting first and attributing**, and never
/// a conclusion: an author naming a launcher, a graphics setting or a shared fix
/// is the common case, and nothing here can tell those apart from a base mod.
///
/// `_bAdvancedRequirementsExist` sits beside it on the profile and is not
/// modelled — it flags that the author filled in the site's structured
/// requirement editor, which changes nothing about the list itself.
library;

import 'gb_coerce.dart';

/// A GameBanana mod page url, in the forms `_aRequirements` actually carries.
///
/// Anchored on the host so a link to some other site's `/mods/123` cannot be
/// read as a mod id, and tolerant of what follows the number — authors paste
/// urls with `#Files` and query strings on them.
final RegExp _modUrl = RegExp(
  r'^(?:https?:)?//(?:www\.)?gamebanana\.com/mods/(\d+)',
  caseSensitive: false,
);

class GbRequirement {
  const GbRequirement({required this.label, this.url});

  /// What the author typed. May be empty — the site accepts a bare url.
  final String label;

  /// Where they pointed, if anywhere. May be any site, or empty.
  final String? url;

  /// The GameBanana mod this points at, when it points at one.
  ///
  /// Null for a label with no link, for a link to anywhere else (a launcher's
  /// GitHub release is the single most common value in the wild), and for a link
  /// to a GameBanana page that is not a mod.
  int? get modId {
    final target = url;
    if (target == null || target.isEmpty) return null;
    final match = _modUrl.firstMatch(target.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Parses the wire form: a list of `[label, url]` pairs.
  ///
  /// Every field is optional in practice, so a malformed entry contributes
  /// nothing rather than throwing — this is a decoration on a detail screen, and
  /// a mod page that renders is worth more than one that fails over a
  /// requirement list.
  static List<GbRequirement> listFrom(Object? value) {
    if (value is! List) return const <GbRequirement>[];
    final parsed = <GbRequirement>[];
    for (final entry in value) {
      if (entry is List) {
        final label = entry.isNotEmpty ? gbString(entry[0]) : null;
        final url = entry.length > 1 ? gbString(entry[1]) : null;
        if (label == null && url == null) continue;
        parsed.add(GbRequirement(label: label ?? '', url: url));
      } else if (entry is Map) {
        // Not observed, but the API has moved list-of-lists to list-of-objects
        // elsewhere; reading both costs one branch.
        final label = gbString(entry['_sName'] ?? entry['name']);
        final url = gbString(entry['_sUrl'] ?? entry['url']);
        if (label == null && url == null) continue;
        parsed.add(GbRequirement(label: label ?? '', url: url));
      }
    }
    return parsed;
  }

  @override
  String toString() => 'GbRequirement($label${url == null ? '' : ' → $url'})';
}
