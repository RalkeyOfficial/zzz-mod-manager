import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/keybind_info.dart';
import 'package:mod_manager_flutter/services/update_apply/keybind_changes.dart';

/// The one thing an update tells the user it took away from them.
///
/// What matters here is that it stays *quiet* when nothing moved — a section
/// that appears after every update is a section people learn to skip, and this
/// one is the only warning that a hotkey they rely on has gone.
void main() {
  KeybindInfo bind(String section, String? key) => KeybindInfo(
        section: section,
        keys: {if (key != null) 'key': key, 'type': 'cycle'},
      );

  test('a moved key is reported with both sides', () {
    final changes = keybindChanges(
      before: [bind('KeySkin', 'F7')],
      after: [bind('KeySkin', 'F9')],
    );
    expect(changes.single.displayName, 'Skin');
    expect(changes.single.before, 'F7');
    expect(changes.single.after, 'F9');
    expect(changes.single.kind, KeybindChangeKind.rebound);
  });

  test('an unchanged key is not reported', () {
    expect(
      keybindChanges(
        before: [bind('KeySkin', 'F7')],
        after: [bind('KeySkin', 'F7')],
      ),
      isEmpty,
    );
  });

  test('VK_ spelling is not a change the user could act on', () {
    // The keybinds view already strips the prefix for display, so `VK_F7` and
    // `F7` are the same key written two ways. Reporting that as a change would
    // be reporting on the author's editor.
    expect(
      keybindChanges(
        before: [bind('KeySkin', 'VK_F7')],
        after: [bind('KeySkin', 'F7')],
      ),
      isEmpty,
    );
  });

  test('modifier order is not a change either', () {
    expect(
      keybindChanges(
        before: [bind('KeySkin', 'ctrl VK_F7')],
        after: [bind('KeySkin', 'F7 ctrl')],
      ),
      isEmpty,
    );
  });

  test('a section the new version dropped is reported as gone', () {
    final changes = keybindChanges(
      before: [bind('KeyGlow', 'F8')],
      after: [bind('KeySkin', 'F7')],
    );
    expect(changes.single.kind, KeybindChangeKind.removed);
    expect(changes.single.before, 'F8');
    expect(changes.single.after, isNull);
  });

  test('a section that binds nothing had nothing to lose', () {
    expect(
      keybindChanges(before: [bind('KeySkin', null)], after: const []),
      isEmpty,
    );
  });

  test('a key the new version added is not a change to anything you had', () {
    // It would otherwise land under a heading about what the update took away.
    expect(
      keybindChanges(before: const [], after: [bind('KeyNew', 'F4')]),
      isEmpty,
    );
  });

  test('sections are matched case-insensitively', () {
    expect(
      keybindChanges(
        before: [bind('keyskin', 'F7')],
        after: [bind('KeySkin', 'F7')],
      ),
      isEmpty,
    );
  });

  test('the list is ordered by name so it does not reshuffle between runs', () {
    final changes = keybindChanges(
      before: [bind('KeyZoom', 'F3'), bind('KeyAlpha', 'F1')],
      after: [bind('KeyZoom', 'F4'), bind('KeyAlpha', 'F2')],
    );
    expect(changes.map((c) => c.displayName), ['Alpha', 'Zoom']);
  });
}
