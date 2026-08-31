import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/screens/components/resolve/identity_search_panel.dart';

/// **What the search box starts with when you ask which mod something is.**
///
/// The only thing available to seed it with is the mod's own name, and that name
/// came from a folder inside an archive — so it routinely arrives as
/// `Ellen_Joe_Cheongsam`. Searched verbatim that finds nothing, and the first
/// thing the user has to do is retype what the app already knew.
///
/// This is a **first guess, not a parse.** It only undoes the substitutions a
/// filename makes for a space, and leaves everything else exactly as the author
/// wrote it: the user edits the box either way, and a clever guess that drops
/// half the name is worse than a plain one.
void main() {
  test('underscores are the separator a filename uses for a space', () {
    expect(searchSeedFromName('Ellen_Joe_Cheongsam'), 'Ellen Joe Cheongsam');
  });

  test('a name that already reads as words is left alone', () {
    expect(searchSeedFromName('Ellen Joe Cheongsam'), 'Ellen Joe Cheongsam');
  });

  test('runs of separators collapse to one space', () {
    // `Ellen__Joe` and `Ellen _ Joe` are both one gap, and a double space in a
    // search is not what either author meant.
    expect(searchSeedFromName('Ellen__Joe'), 'Ellen Joe');
    expect(searchSeedFromName('Ellen _ Joe'), 'Ellen Joe');
  });

  test('leading and trailing separators go', () {
    expect(searchSeedFromName('_Ellen_'), 'Ellen');
    expect(searchSeedFromName('  Ellen  '), 'Ellen');
  });

  test('hyphens and dots are the author writing, not a separator', () {
    // "Ellen - Swimsuit" and "v1.2" are how mod pages are actually titled.
    // Replacing these would change the words rather than restore them.
    expect(searchSeedFromName('Ellen - Swimsuit v1.2'), 'Ellen - Swimsuit v1.2');
  });

  test('a name that is only separators leaves the box empty', () {
    // Rather than a lone space, which searches for everything.
    expect(searchSeedFromName('___'), '');
  });
}
