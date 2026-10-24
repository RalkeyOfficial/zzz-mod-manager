import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Browse keeps its hidden pages mounted in an `IndexedStack` and relies on it to keep them out of Tab's reach. This
/// pins that, so an SDK that stops doing it fails here rather than in the running app. No localized strings are
/// involved, so a plain `MaterialApp` is enough.
void main() {
  testWidgets('a field in a hidden page of an IndexedStack cannot take focus', (tester) async {
    final hidden = FocusNode();
    final shown = FocusNode();
    addTearDown(hidden.dispose);
    addTearDown(shown.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: IndexedStack(
            index: 1,
            children: [
              TextField(focusNode: hidden),
              TextField(focusNode: shown),
            ],
          ),
        ),
      ),
    );

    hidden.requestFocus();
    await tester.pump();
    expect(hidden.hasFocus, isFalse, reason: 'a hidden page must not take focus');

    shown.requestFocus();
    await tester.pump();
    expect(shown.hasFocus, isTrue);
  });
}
