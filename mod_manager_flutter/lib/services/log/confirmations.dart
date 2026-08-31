/// What the user was asked, and what they answered.
///
/// The log records what the app did; this records what it was **allowed** to
/// do. It is the difference between "it overwrote my mod" and a line showing
/// the overwrite was offered, described, and accepted — and, just as often, the
/// answer to "I pressed the button and nothing happened", which is nearly always
/// a prompt that was declined or dismissed.
///
/// **A decline is logged as loudly as an accept.** An action that did not happen
/// leaves no other trace anywhere, so it is the half more likely to be missing
/// when somebody goes looking.
///
/// There is no funnel to hook the way notifications have one: these dialogs
/// return `bool`, an enum, a map of destinations. Forcing them through a common
/// type would be a refactor pretending to be logging, so this is called by hand
/// where each answer is **consumed** — that is where the subject and the
/// consequence are both known.
library;

import 'logger.dart';

final Logger _log = Logger('ui.confirm');

/// [action] is a dotted verb — `update.apply`, `mod.delete`,
/// `snapshot.restore`, `patch.destination`. [subject] is what it would happen
/// to, usually a mod name.
void logConfirmation(
  String action, {
  required bool accepted,
  required String subject,
  bool dismissed = false,
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  _log.info('answered', fields: {
    'action': action,
    'decision': accepted ? 'accepted' : 'declined',
    // Told apart because they mean different things about the user: closing a
    // dialog by clicking away is not the same as reading it and saying no.
    if (dismissed) 'dismissed': true,
    'subject': subject,
    ...fields,
  });
}
