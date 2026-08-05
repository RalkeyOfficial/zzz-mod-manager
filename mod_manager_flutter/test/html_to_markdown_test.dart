import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_page.dart';
import 'package:mod_manager_flutter/utils/html_to_markdown.dart';

import 'support/fixtures.dart';

/// GameBanana's `_sText` is HTML while every description we store and render is
/// markdown, so this conversion sits between the API and the detail view. The
/// point of testing it against a real `_sText` is that the tags GameBanana
/// actually emits are not the ones you would guess.
void main() {
  test('empty and whitespace input convert to empty, not to junk', () {
    expect(htmlToMarkdown(''), '');
    expect(htmlToMarkdown('   \n  '), '');
  });

  test('the house style is ATX headings and - bullets', () {
    expect(htmlToMarkdown('<h2>Title</h2>'), '## Title');
    // html2md pads after the marker (`-   one`); the marker is what the house
    // style pins, not the padding, so match on that rather than byte-for-byte.
    final bullets = htmlToMarkdown('<ul><li>one</li><li>two</li></ul>');
    expect(bullets.split('\n').map((l) => l.trimRight()).toList(), [
      startsWith('-'),
      startsWith('-'),
    ]);
    expect(bullets, contains('one'));
    expect(bullets, contains('two'));
    expect(bullets, isNot(contains('*')));
  });

  test('inline emphasis and links survive', () {
    expect(htmlToMarkdown('<b>bold</b>'), '**bold**');
    expect(htmlToMarkdown('<i>it</i>'), '_it_');
    expect(
      htmlToMarkdown('<a href="https://example.com">link</a>'),
      '[link](https://example.com)',
    );
  });

  test('<br> becomes a line break rather than being swallowed', () {
    // GameBanana uses <br> for essentially all of its line structure, so losing
    // it would collapse a whole description into one paragraph.
    expect(htmlToMarkdown('a<br>b'), contains('a'));
    expect(htmlToMarkdown('a<br>b'), contains('b'));
    expect(htmlToMarkdown('a<br>b').contains('\n'), isTrue);
  });

  test('a styling span keeps its text and drops the markup', () {
    // GameBanana wraps emphasis in <span class="RedColor">, which has no
    // markdown equivalent — the text must survive, the class must not leak.
    final out = htmlToMarkdown('<span class="RedColor">Important</span>');
    expect(out, contains('Important'));
    expect(out, isNot(contains('RedColor')));
    expect(out, isNot(contains('<span')));
  });

  group('a real _sText', () {
    late String markdown;

    setUpAll(() {
      final mod = GbMod.fromJson(parseObject(loadGbFixture('mod_profile_531649')))!;
      markdown = htmlToMarkdown(mod.text!);
    });

    test('produces no residual HTML tags', () {
      // The failure this guards is a raw tag reaching a markdown widget, which
      // renders as literal angle brackets in the user's face.
      expect(markdown, isNot(contains('<br')));
      expect(markdown, isNot(contains('<h1')));
      expect(markdown, isNot(contains('<span')));
      expect(markdown, isNot(contains('</')));
    });

    test('keeps the prose and promotes the headings', () {
      expect(markdown, contains('!Important Warning!'));
      expect(markdown, contains('RabbitFX'));
      expect(markdown, contains('# '));
    });

    test('is not empty and not absurdly larger than the source', () {
      expect(markdown.length, greaterThan(1000));
      expect(markdown.length, lessThan(mod531649TextLength));
    });
  });
}

/// Length of the captured `_sText`; the conversion should shrink it (tags out,
/// no wrappers in), so a result larger than this means something is escaping
/// aggressively.
const int mod531649TextLength = 18126;
