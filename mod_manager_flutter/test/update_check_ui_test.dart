import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/dialogs/mod_update_dialog.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_endpoints.dart';
import 'package:mod_manager_flutter/services/update_check.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';

/// The two surfaces the update check reaches the user through: the toolbar
/// button that checks the whole library, and the per-mod dialog.
void main() {
  ModOrigin origin({int? modId = 531649, int? fileId, DateTime? installedAt}) =>
      ModOrigin(
        source: modId == null ? null : 'gamebanana',
        modId: modId,
        modIdConfidence:
            modId == null ? OriginConfidence.unknown : OriginConfidence.user,
        fileId: fileId,
        versionConfidence:
            fileId == null ? OriginConfidence.unknown : OriginConfidence.user,
        provenance: OriginProvenance.downloaded,
        installedAt: installedAt,
      );

  ModInfo mod(String name, {ModOrigin? origin}) => ModInfo(
        id: name,
        name: name,
        characterId: 'ellen',
        isActive: false,
        origin: origin,
      );

  GbMod record(int modId, {int fileId = 10}) => GbMod(
        idRow: modId,
        files: [GbFile(idRow: fileId, dateAdded: DateTime.utc(2026))],
      );

  group('the toolbar button', () {
    late ProviderContainer container;

    Future<void> pumpToolbar(
      WidgetTester tester,
      List<CharacterInfo> groups, {
      ModRecordFetcherStub? fetch,
      Size surfaceSize = const Size(1200, 800),
    }) async {
      await tester.pumpWidget(const SizedBox());
      container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(charactersProvider.notifier).state = groups;

      await pumpLocalized(
        tester,
        ModsToolbar(
          updateFetcher: fetch == null
              ? (ids) async => throw StateError('no fetch expected')
              : fetch.call,
        ),
        container: container,
        surfaceSize: surfaceSize,
      );
      expectBuilt(ModsToolbar);
    }

    testWidgets('is absent when nothing in the library is tracked',
        (tester) async {
      // A legacy library that has never been resolved has nothing to check, and
      // a control that can only ever report nothing is noise in a toolbar that
      // already carries five.
      await pumpToolbar(tester, [
        CharacterInfo(id: 'all', name: 'All', skins: [mod('bare')]),
      ]);
      expect(find.byIcon(Icons.arrow_circle_up), findsNothing);
    });

    testWidgets('covers the whole library, not the selected character',
        (tester) async {
      // The deliberate departure from where the "assume current" button gets
      // its list. That one *rewrites*, so it must not act past the edge of the
      // grid; this one writes nothing and its badges are drawn on every tab, so
      // scoping it to one character would leave the rest looking clean.
      final asked = <int>[];
      final fetch = ModRecordFetcherStub((ids) async {
        asked.addAll(ids);
        return [for (final id in ids) record(id)];
      });
      await pumpToolbar(
        tester,
        [
          CharacterInfo(
            id: 'ellen',
            name: 'Ellen',
            skins: [mod('a', origin: origin(modId: 1, fileId: 10))],
          ),
          CharacterInfo(
            id: 'rina',
            name: 'Rina',
            skins: [mod('b', origin: origin(modId: 2, fileId: 10))],
          ),
        ],
        fetch: fetch,
      );
      // Index 0 is selected, so the grid is showing Ellen's one mod.
      expect(container.read(currentCharacterSkinsProvider), hasLength(1));

      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();

      expect(asked, [1, 2]);
    });

    testWidgets('reports what it found, and badges the count', (tester) async {
      final fetch = ModRecordFetcherStub(
        // File 99 is not among what mod 1 offers, so it has been superseded.
        (ids) async => [record(1, fileId: 10)],
      );
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('current', origin: origin(modId: 1, fileId: 10)),
            mod('stale', origin: origin(modId: 1, fileId: 99)),
          ]),
        ],
        fetch: fetch,
      );

      // No number before a run: "0 updates" and "not checked yet" are different
      // states, and a zero would assert the first while meaning the second.
      expect(find.text('0'), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();

      expect(find.text('1'), findsOneWidget);
      expect(find.text('1 mod has an update'), findsOneWidget);
      expect(
        container.read(modUpdateChecksProvider)['stale']?.outcome,
        UpdateOutcome.updateAvailable,
      );
    });

    testWidgets('becomes a filter once it has found something', (tester) async {
      // One control, two jobs. A seventh toolbar control was the obvious
      // alternative and was rejected — so the rule keeping this legible is
      // "the button does the only useful thing available", and the count is
      // the visible signal for which mode it is in.
      final fetch = ModRecordFetcherStub((ids) async => [record(1, fileId: 10)]);
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('current', origin: origin(modId: 1, fileId: 10)),
            mod('stale', origin: origin(modId: 1, fileId: 99)),
          ]),
        ],
        fetch: fetch,
      );

      // Check mode: no count, and pressing runs the check.
      expect(container.read(modUpdatesOnlyProvider), isFalse);
      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(container.read(modUpdatesOnlyProvider), isFalse,
          reason: 'the first press checked, it did not filter');
      expect(find.text('1'), findsOneWidget);

      // Filter mode: the same control now narrows the grid instead.
      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(container.read(modUpdatesOnlyProvider), isTrue);
      expect(container.read(visibleModsProvider).map((m) => m.id), ['stale']);
      // …and it is a toggle, not a one-way door.
      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(container.read(modUpdatesOnlyProvider), isFalse);
      expect(container.read(visibleModsProvider), hasLength(2));
    });

    testWidgets('re-checking moves to the row below while filtering',
        (tester) async {
      // The cost of overloading the button: the action needs somewhere to go.
      // This is the shape the bulk "assume current" button already uses.
      var runs = 0;
      final fetch = ModRecordFetcherStub((ids) async {
        runs++;
        return [record(1, fileId: 10)];
      });
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('stale', origin: origin(modId: 1, fileId: 99)),
          ]),
        ],
        fetch: fetch,
      );

      expect(find.text('Check again'), findsNothing);
      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(find.text('Check again'), findsNothing,
          reason: 'not offered until the button is actually held by the filter');

      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(find.text('Check again'), findsOneWidget);
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(runs, 2);
    });

    testWidgets('switches itself off when the last update is dealt with',
        (tester) async {
      // Ignoring the last flagged mod would otherwise leave the grid filtered
      // to nothing, with a control the user has to work out they need to press.
      final target = mod('a', origin: origin(modId: 1, fileId: 99));
      await pumpToolbar(tester, [
        CharacterInfo(id: 'all', name: 'All', skins: [target]),
      ]);
      container.read(modUpdateChecksProvider.notifier).state = {
        'a': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
      };
      container.read(modUpdatesOnlyProvider.notifier).state = true;
      await tester.pumpAndSettle();
      expect(container.read(visibleModsProvider), hasLength(1));

      // The dialog's "ignore" lands here: the verdict stays, `hasUpdate` goes.
      container.read(modUpdateChecksProvider.notifier).state = {
        'a': const UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          dismissed: true,
        ),
      };
      await tester.pumpAndSettle();

      expect(container.read(modUpdatesOnlyProvider), isFalse);
      expect(container.read(visibleModsProvider), hasLength(1),
          reason: 'the grid is whole again, not empty');
    });

    testWidgets('but not merely because this character tab has none',
        (tester) async {
      // The trap in keying that on the *view* count: the filter would evaporate
      // the moment the user looked at a tab with no updates of its own.
      final flagged = mod('rina', origin: origin(modId: 1, fileId: 99));
      await pumpToolbar(tester, [
        CharacterInfo(id: 'all', name: 'All', skins: [flagged]),
        CharacterInfo(id: 'ellen', name: 'Ellen', skins: [
          mod('ellen skin', origin: origin(modId: 2, fileId: 10)),
        ]),
      ]);
      container.read(modUpdateChecksProvider.notifier).state = {
        'rina': const UpdateCheck(outcome: UpdateOutcome.updateAvailable),
      };
      container.read(modUpdatesOnlyProvider.notifier).state = true;
      await tester.pumpAndSettle();

      // Switch to the tab with none of its own.
      container.read(selectedCharacterIndexProvider.notifier).state = 1;
      await tester.pumpAndSettle();

      expect(container.read(modsWithUpdatesCountProvider), 0);
      expect(container.read(modUpdatesOnlyProvider), isTrue,
          reason: 'the library still has one, so the filter stands');
      // And the control is still there to switch off by hand.
      expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);
    });

    testWidgets('clearing the filters turns it off too', (tester) async {
      await pumpToolbar(tester, [
        CharacterInfo(id: 'all', name: 'All', skins: [
          mod('a', origin: origin(modId: 1, fileId: 10)),
        ]),
      ]);
      container.read(modUpdatesOnlyProvider.notifier).state = true;
      await tester.pumpAndSettle();

      expect(find.text('Clear filters'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(container.read(modUpdatesOnlyProvider), isFalse);
    });

    testWidgets('the second row survives all three buttons at 480px',
        (tester) async {
      // Where the last overflow bug came from: none of these labels can
      // ellipsise, so a Row that doesn't fit degrades into a red stripe rather
      // than into anything. That row is a Wrap for exactly this.
      //
      // Reaching all three at once takes some doing, and the reason is worth
      // recording: the two status filters AND like every other filter, and a
      // mod that needs attention (no recorded version) usually has no update
      // either — so combining them normally empties the grid and the
      // "assume current" button has nothing to act on. The exception is a mod
      // identified by a **banked archive hash**, which can carry an update while
      // its version is still unrecorded. That is the case built here.
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            for (var i = 0; i < 120; i++)
              mod(
                'mod $i',
                origin: origin(
                  modId: 1,
                  installedAt: DateTime.utc(2026, 5, 8),
                ),
              ),
          ]),
        ],
        surfaceSize: const Size(480, 400),
      );
      container.read(modUpdateChecksProvider.notifier).state = {
        for (var i = 0; i < 120; i++)
          'mod $i': const UpdateCheck(
            outcome: UpdateOutcome.updateAvailable,
            evidence: InstalledFileEvidence.archiveHash,
          ),
      };
      container.read(modUpdatesOnlyProvider.notifier).state = true;
      container.read(modNeedsAttentionOnlyProvider.notifier).state = true;
      await tester.pumpAndSettle();

      expect(find.text('Clear filters'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.textContaining('Assume'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('says so when some mods could not be reached', (tester) async {
      // "No updates" and "no updates among the mods we could actually reach"
      // are different statements, and reporting the second as the first turns a
      // network failure into false reassurance across a whole library.
      final fetch = ModRecordFetcherStub(
        (ids) async => throw const GbNetworkException('offline'),
      );
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('a', origin: origin(modId: 1, fileId: 10)),
          ]),
        ],
        fetch: fetch,
      );

      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();

      expect(find.text('No updates found'), findsNothing);
      expect(find.textContaining("couldn't be checked"), findsOneWidget);
    });
  });

  group('the per-mod dialog', () {
    /// A client wired to a scripted transport, so nothing here can reach the
    /// network — `GameBananaClient`'s only seam.
    (GameBananaClient, FakeHttpTransport) fakeClient() {
      final transport = FakeHttpTransport();
      final endpoints = GameBananaEndpoints(gameId: 19567);
      transport.stub(
        endpoints.modProfile(531649),
        body: loadGbFixture('mod_profile_531649'),
      );
      // The release feed is fetched alongside the profile. RabbitFX's own is
      // not captured, and an empty one is the honest stand-in: most mods have
      // no grouping to apply, and the verdict must be identical either way.
      transport.stub(
        endpoints.modUpdates(531649),
        body: '{"_aMetadata":{"_nRecordCount":0},"_aRecords":[]}',
      );
      return (
        GameBananaClient(transport: transport, endpoints: endpoints),
        transport,
      );
    }

    Future<List<ModOrigin?>> pumpDialog(
      WidgetTester tester,
      ModInfo target,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final (client, _) = fakeClient();
      final written = <ModOrigin?>[];
      await pumpLocalized(
        tester,
        ModUpdateDialog(
          mod: target,
          gateway: _RecordingGateway(target.origin, written),
        ),
        overrides: [gameBananaClientProvider.overrideWithValue(client)],
      );
      return written;
    }

    testWidgets('checks on open and states the verdict', (tester) async {
      // File 1696178 is RabbitFX v7.4, archived on the real captured page.
      await pumpDialog(
        tester,
        mod('Ellen', origin: origin(fileId: 1696178)),
      );
      await tester.pumpAndSettle();

      expect(find.text('An update is available'), findsOneWidget);
      // Both sides of the comparison are named, not just the verdict.
      expect(find.textContaining('7.4'), findsWidgets);
      expect(find.textContaining('7.7'), findsWidgets);
    });

    testWidgets('the newest file reads as current, with no update action',
        (tester) async {
      await pumpDialog(
        tester,
        mod('Ellen', origin: origin(fileId: 1732269)),
      );
      await tester.pumpAndSettle();

      expect(find.text('This is the latest file'), findsOneWidget);
      // The marketplace shortcut is for a mod that has somewhere to go.
      expect(find.text('View in marketplace'), findsNothing);
    });

    testWidgets('a guessed answer is labelled as one', (tester) async {
      // The locked decision: with a guessed installed version the strongest
      // available claim is "possibly", and the caveat has to be visible.
      final guessed = ModOrigin(
        source: 'gamebanana',
        modId: 531649,
        modIdConfidence: OriginConfidence.inferred,
        fileId: 1696178,
        versionConfidence: OriginConfidence.inferred,
        provenance: OriginProvenance.importedFolder,
      );
      await pumpDialog(tester, mod('Ellen', origin: guessed));
      await tester.pumpAndSettle();

      expect(find.text('Possibly outdated'), findsOneWidget);
      expect(find.textContaining('best guess'), findsOneWidget);
    });

    testWidgets('an untracked mod asks nothing and points at the fix',
        (tester) async {
      await pumpDialog(tester, mod('Ellen', origin: null));
      await tester.pumpAndSettle();

      expect(find.text('Not tracked for updates'), findsOneWidget);
      expect(find.textContaining('Update tracking'), findsOneWidget);
      // Nothing to open a mod page for, and nothing to retry — this answer
      // came from the sidecar, so no request was made and none would help.
      expect(find.text('Try again'), findsNothing);
      expect(find.text('Open mod page'), findsNothing);
    });

    testWidgets('a retry appears only when the check actually failed',
        (tester) async {
      // There is no general "check again": a verdict from the bulk pass is
      // fresh, and a dialog opened without one checks on the way in. Neither
      // leaves anything to press. A failure does — and closing and reopening
      // should not be the only way back.
      await tester.pumpWidget(const SizedBox());
      final transport = FakeHttpTransport();
      final endpoints = GameBananaEndpoints(gameId: 19567);
      // One-shot failure, then a standing success: `enqueue` is consumed by the
      // next matching request while `stub` repeats, so this scripts "offline,
      // then fine" without the second setup having to replace the first.
      transport.enqueue(endpoints.modProfile(531649), statusCode: 500);
      transport.stub(
        endpoints.modProfile(531649),
        body: loadGbFixture('mod_profile_531649'),
      );
      transport.stub(
        endpoints.modUpdates(531649),
        body: '{"_aMetadata":{"_nRecordCount":0},"_aRecords":[]}',
      );
      final target = mod('Ellen', origin: origin(fileId: 1696178));

      await pumpLocalized(
        tester,
        ModUpdateDialog(
          mod: target,
          gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
        ),
        overrides: [
          gameBananaClientProvider.overrideWithValue(
            GameBananaClient(transport: transport, endpoints: endpoints),
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't reach GameBanana"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      // And a successful check leaves no retry behind.
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('An update is available'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('ignoring an update writes it and silences the badge',
        (tester) async {
      // The escape hatch: an update the user does not want should stop marking
      // the card without turning tracking off, and without hiding the finding
      // from the dialog they would open to change their mind.
      final target = mod('Ellen', origin: origin(fileId: 1696178));
      final written = await pumpDialog(tester, target);
      await tester.pumpAndSettle();
      expect(find.text('An update is available'), findsOneWidget);

      await tester.tap(find.text('Ignore this update'));
      await tester.pumpAndSettle();

      // Written as the date of the thing dismissed, not as "now" — anything
      // published later must still speak up.
      expect(written, hasLength(1));
      expect(written.single?.updatesDismissedUntil, DateTime.utc(2026, 6, 19, 12, 39, 6));
      // The verdict stays on screen; only the badge goes quiet.
      expect(find.text('An update is available'), findsOneWidget);
      expect(find.textContaining("You're ignoring this update"), findsOneWidget);
      expect(find.text('Stop ignoring it'), findsOneWidget);
    });

    testWidgets('…including when the dialog was opened from the card badge',
        (tester) async {
      // **The path that was broken and untested.** Arriving from the badge
      // means a verdict is already on record, so the dialog fetches no mod
      // page at all — and the dismissal used to be re-derived *from* that page,
      // producing nothing. The write succeeded and every surface kept showing
      // the pre-dismissal state, which reads as a button that does nothing.
      await tester.pumpWidget(const SizedBox());
      final (client, transport) = fakeClient();
      final target = mod('Ellen', origin: origin(fileId: 1696178));
      final written = <ModOrigin?>[];
      final container = ProviderContainer(overrides: [
        gameBananaClientProvider.overrideWithValue(client),
      ]);
      addTearDown(container.dispose);
      container.read(modUpdateChecksProvider.notifier).state = {
        'Ellen': UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          candidate: GbFile(idRow: 1732269, dateAdded: DateTime.utc(2026, 6, 19)),
        ),
      };

      await pumpLocalized(
        tester,
        ModUpdateDialog(
          mod: target,
          gateway: _RecordingGateway(target.origin, written),
        ),
        container: container,
      );
      await tester.pumpAndSettle();
      expect(transport.callCount, 0, reason: 'the badge path fetches nothing');

      await tester.tap(find.text('Ignore this update'));
      await tester.pumpAndSettle();

      expect(written, hasLength(1));
      expect(find.text('Stop ignoring it'), findsOneWidget);
      // The three surfaces that were stale: this dialog, the card badge and the
      // toolbar count all read the same map.
      expect(container.read(modUpdateChecksProvider)['Ellen']?.dismissed, isTrue);
      expect(container.read(modUpdateChecksProvider)['Ellen']?.hasUpdate, isFalse);

      // And it undoes from the same place.
      await tester.tap(find.text('Stop ignoring it'));
      await tester.pumpAndSettle();
      expect(container.read(modUpdateChecksProvider)['Ellen']?.hasUpdate, isTrue);
      expect(written.last?.updatesDismissedUntil, isNull);
    });

    testWidgets('several newer files are offered as a choice, not one answer',
        (tester) async {
      // The reported scenario: an SFW install, an NSFW sibling already ignored,
      // and then the author updates both. Naming a single file here hides the
      // decision from the one person who knows which variant they run.
      await tester.pumpWidget(const SizedBox());
      final (client, _) = fakeClient();
      final target = mod('Ellen', origin: origin(fileId: 10));
      final container = ProviderContainer(overrides: [
        gameBananaClientProvider.overrideWithValue(client),
      ]);
      addTearDown(container.dispose);
      container.read(modUpdateChecksProvider.notifier).state = {
        'Ellen': UpdateCheck(
          outcome: UpdateOutcome.updateAvailable,
          candidateMatchesVariant: true,
          candidate: GbFile(
            idRow: 20,
            description: 'SFW Variants Only',
            dateAdded: DateTime.utc(2026, 6, 1),
          ),
          newerFiles: [
            GbFile(
              idRow: 21,
              description: 'NSFW Variants Included',
              dateAdded: DateTime.utc(2026, 6, 1, 0, 2),
            ),
            GbFile(
              idRow: 20,
              description: 'SFW Variants Only',
              dateAdded: DateTime.utc(2026, 6, 1),
            ),
          ],
        ),
      };

      await pumpLocalized(
        tester,
        ModUpdateDialog(
          mod: target,
          gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
        ),
        container: container,
      );
      await tester.pumpAndSettle();

      // Both variants are on screen…
      expect(find.text('SFW Variants Only'), findsOneWidget);
      expect(find.text('NSFW Variants Included'), findsOneWidget);
      // …exactly one is marked, and the chip says *why* it was marked, which is
      // the difference between a real match and a fallback to the newest file.
      expect(find.text('matches your variant'), findsOneWidget);
      expect(find.text('newest published'), findsNothing);
      // The single-file line is not also drawn — one shape or the other.
      expect(find.text('Published'), findsNothing);
    });

    testWidgets('and says when the mark is only a fallback', (tester) async {
      // Labels drifted, so the pick is merely the newest file and may well be
      // somebody else's variant. Presenting that identically to a real match is
      // the whole failure this chip exists to prevent.
      await tester.pumpWidget(const SizedBox());
      final (client, _) = fakeClient();
      final target = mod('Ellen', origin: origin(fileId: 10));
      final container = ProviderContainer(overrides: [
        gameBananaClientProvider.overrideWithValue(client),
      ]);
      addTearDown(container.dispose);
      container.read(modUpdateChecksProvider.notifier).state = {
        'Ellen': UpdateCheck(
          outcome: UpdateOutcome.possiblyOutdated,
          isGuess: true,
          candidate: GbFile(
            idRow: 21,
            description: 'NSFW',
            dateAdded: DateTime.utc(2026, 6, 1, 0, 2),
          ),
          newerFiles: [
            GbFile(
              idRow: 21,
              description: 'NSFW',
              dateAdded: DateTime.utc(2026, 6, 1, 0, 2),
            ),
            GbFile(
              idRow: 20,
              description: 'SFW',
              dateAdded: DateTime.utc(2026, 6, 1),
            ),
          ],
        ),
      };

      await pumpLocalized(
        tester,
        ModUpdateDialog(
          mod: target,
          gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
        ),
        container: container,
      );
      await tester.pumpAndSettle();

      expect(find.text('newest published'), findsOneWidget);
      expect(find.text('matches your variant'), findsNothing);
    });

    testWidgets('an already-checked mod is not re-fetched on open',
        (tester) async {
      // Re-checking what the bulk pass just answered spends a request to redraw
      // the same sentence — and would very likely be served from the client's
      // ten-minute cache anyway, which looks identical to doing nothing.
      await tester.pumpWidget(const SizedBox());
      final (client, transport) = fakeClient();
      await pumpLocalized(
        tester,
        ModUpdateDialog(mod: mod('Ellen', origin: origin(fileId: 1732269))),
        overrides: [
          gameBananaClientProvider.overrideWithValue(client),
          modUpdateChecksProvider.overrideWith(
            (ref) => {'Ellen': const UpdateCheck(outcome: UpdateOutcome.upToDate)},
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(transport.callCount, 0);
      expect(find.text('This is the latest file'), findsOneWidget);
    });
  });
}

/// Captures what the dialog would write, instead of touching the real sidecar
/// (and, through `ApiService`, the developer's real `config.json`).
class _RecordingGateway implements ModUpdateGateway {
  _RecordingGateway(this._current, this._written);
  final ModOrigin? _current;
  final List<ModOrigin?> _written;

  @override
  Future<bool> writeOrigin(
    String modId,
    ModOrigin? Function(ModOrigin? current) update,
  ) async {
    _written.add(update(_current));
    return true;
  }
}

/// A callable holder, so a stub can be passed where a bare function type is
/// expected without the closure being re-created on every rebuild.
class ModRecordFetcherStub {
  ModRecordFetcherStub(this._fn);
  final Future<List<GbMod>> Function(List<int>) _fn;
  Future<List<GbMod>> call(List<int> ids) => _fn(ids);
}
