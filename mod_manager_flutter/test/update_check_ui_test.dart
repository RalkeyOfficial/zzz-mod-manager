import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_exceptions.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/models/mod_companion.dart';
import 'package:mod_manager_flutter/models/mod_ingest.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/components/mods_toolbar.dart';
import 'package:mod_manager_flutter/screens/dialogs/bulk_resolution_dialog.dart';
import 'package:mod_manager_flutter/screens/dialogs/mod_update_dialog.dart';
import 'package:mod_manager_flutter/services/bulk_update_check.dart';
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
      List<String>? written,
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
          // Never the real `ApiService`: it lazily builds a `ConfigService`
          // against the developer's own `<appData>/config.json`.
          originWriter: (name, update) async {
            written?.add(name);
            return written != null;
          },
        ),
        container: container,
        surfaceSize: surfaceSize,
      );
      expectBuilt(ModsToolbar);
    }

    /// Picks an entry out of the library menu — the one place the three bulk
    /// actions live now that none of them is overloaded onto a filter.
    Future<void> runAction(WidgetTester tester, String label) async {
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('nothing tracked means the check is offered but disabled',
        (tester) async {
      // Disabled rather than hidden, because it lives in a menu now: an entry
      // reading "Check for updates  0" says why it can do nothing, where a
      // missing entry would just look like the feature isn't there.
      await pumpToolbar(tester, [
        CharacterInfo(id: 'all', name: 'All', skins: [mod('bare')]),
      ]);
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(find.text('Check for updates'), findsOneWidget);

      // Pressing it does nothing at all — the fetcher this toolbar was given
      // throws if it is ever called, and a disabled entry leaves the menu open.
      await tester.tap(find.text('Check for updates'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Check for updates'), findsOneWidget);
    });

    testWidgets('the updates toggle is a filter and nothing else',
        (tester) async {
      // It used to run the check as well, which is why re-checking took three
      // clicks and the results screen had nowhere to be re-opened from. With
      // nothing found there is nothing to filter, so it isn't rendered at all.
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
      expect(find.byIcon(Icons.arrow_circle_up), findsNothing);

      await runAction(tester, 'Check for updates');
      expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);

      // One press filters, a second clears — no hidden second job.
      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(container.read(modUpdatesOnlyProvider), isTrue);
      expect(container.read(visibleModsProvider).map((m) => m.id), ['stale']);

      await tester.tap(find.byIcon(Icons.arrow_circle_up));
      await tester.pumpAndSettle();
      expect(container.read(modUpdatesOnlyProvider), isFalse);
      expect(container.read(visibleModsProvider), hasLength(2));
    });

    testWidgets('the results screen can be re-opened after it is dismissed',
        (tester) async {
      // The complaint that produced the library menu: the screen only ever
      // appeared as a side effect of a check, so cancelling it — or closing it
      // by accident — meant it was gone. The records are session state now, so
      // reopening costs no request at all.
      var runs = 0;
      final fetch = ModRecordFetcherStub((ids) async {
        runs++;
        return [
          GbMod(
            idRow: 1,
            name: 'Ellen Swimsuit',
            files: [
              GbFile(idRow: 10, file: 'e.zip', dateAdded: DateTime.utc(2025)),
            ],
          ),
        ];
      });
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('Ellen',
                origin: origin(modId: 1, installedAt: DateTime.utc(2026))),
          ]),
        ],
        fetch: fetch,
      );

      await runAction(tester, 'Check for updates');
      expect(find.byType(BulkResolutionDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(BulkResolutionDialog), findsNothing);

      await runAction(tester, 'Sort out mod tracking…');
      expect(find.byType(BulkResolutionDialog), findsOneWidget);
      expect(runs, 1, reason: 're-opened from the records already in hand');
    });

    testWidgets('both doors report the same library-wide summary',
        (tester) async {
      // The check door had the pass's own count and the menu door had the
      // *view-scoped* toolbar count, so standing on a character tab the same
      // sentence in the same dialog meant something different. Both read the
      // library now.
      final fetch = ModRecordFetcherStub(
        (ids) async => [
          for (final id in ids)
            GbMod(
              idRow: id,
              name: 'Mod $id',
              files: [
                GbFile(idRow: 10, file: 'e.zip', dateAdded: DateTime.utc(2025)),
              ],
            ),
        ],
      );
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'ellen', name: 'Ellen', skins: [
            mod('Ellen skin',
                origin: origin(modId: 1, installedAt: DateTime.utc(2026))),
          ]),
          CharacterInfo(id: 'rina', name: 'Rina', skins: [
            mod('Rina skin',
                origin: origin(modId: 2, fileId: 99, installedAt: DateTime.utc(2026))),
          ]),
        ],
        fetch: fetch,
      );

      // File 99 is gone from mod 2's list, so Rina — on the *other* tab — is
      // the only mod with an update.
      await runAction(tester, 'Check for updates');
      expect(find.textContaining('1 mod has an update'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await runAction(tester, 'Sort out mod tracking…');
      expect(find.textContaining('1 mod has an update'), findsOneWidget,
          reason: 'the view shows none of its own, the library has one');
    });

    testWidgets('opening it with nothing in hand runs the check first',
        (tester) async {
      // Otherwise the menu's most useful entry is the one greyed out on launch.
      var runs = 0;
      final fetch = ModRecordFetcherStub((ids) async {
        runs++;
        return [
          GbMod(
            idRow: 1,
            name: 'Ellen Swimsuit',
            files: [
              GbFile(idRow: 10, file: 'e.zip', dateAdded: DateTime.utc(2025)),
            ],
          ),
        ];
      });
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('Ellen',
                origin: origin(modId: 1, installedAt: DateTime.utc(2026))),
          ]),
        ],
        fetch: fetch,
      );

      await runAction(tester, 'Sort out mod tracking…');
      expect(runs, 1);
      expect(find.byType(BulkResolutionDialog), findsOneWidget);
    });

    testWidgets('re-checking is one press, whatever the filters are doing',
        (tester) async {
      // The whole cost of the old overload: "check again" only existed while
      // the filter it hid behind was on.
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

      await runAction(tester, 'Check for updates');
      await runAction(tester, 'Check for updates');
      expect(runs, 2);
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

      await runAction(tester, 'Check for updates');

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

      await runAction(tester, 'Check for updates');

      expect(find.text('1'), findsOneWidget);
      expect(find.text('1 mod has an update'), findsOneWidget);
      expect(
        container.read(modUpdateChecksProvider)['stale']?.outcome,
        UpdateOutcome.updateAvailable,
      );
    });

    testWidgets('a fully sorted-out library gets a notification, not a modal',
        (tester) async {
      // The results screen appears only when it has something to ask — the
      // same rule the button itself follows. With nothing to resolve, a modal
      // would stand between the user and the badges they pressed for.
      final fetch = ModRecordFetcherStub((ids) async => [record(1)]);
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('done', origin: origin(modId: 1, fileId: 10)),
          ]),
        ],
        fetch: fetch,
      );
      await runAction(tester, 'Check for updates');

      expect(find.byType(BulkResolutionDialog), findsNothing);
      expect(find.text('No updates found'), findsOneWidget);
    });

    testWidgets('an unresolved mod opens the results screen instead',
        (tester) async {
      // The same press, the same request: the check's own response is what the
      // resolution questions are asked against, so the screen costs nothing
      // extra.
      final fetch = ModRecordFetcherStub(
        (ids) async => [
          GbMod(
            idRow: 1,
            name: 'Ellen Swimsuit',
            files: [
              GbFile(
                idRow: 10,
                file: 'ellen.zip',
                dateAdded: DateTime.utc(2025),
              ),
            ],
          ),
        ],
      );
      final written = <String>[];
      await pumpToolbar(
        tester,
        [
          CharacterInfo(id: 'all', name: 'All', skins: [
            mod('Ellen',
                origin: origin(modId: 1, installedAt: DateTime.utc(2026))),
          ]),
        ],
        fetch: fetch,
        written: written,
      );
      await runAction(tester, 'Check for updates');

      expect(find.byType(BulkResolutionDialog), findsOneWidget);
      // And the summary is stated *here* rather than raised behind it — two
      // reports of one press is how a user ends up reading neither.
      expect(find.text('No updates found'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Save 1 mod'));
      await tester.pumpAndSettle();
      expect(written, ['Ellen']);
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

    testWidgets('the filter row survives every control at 480px',
        (tester) async {
      // Where the last overflow bug came from: none of these labels can
      // ellipsise, so a Row that doesn't fit degrades into a red stripe. The
      // row is a Wrap for exactly this, and it now has to hold five filters
      // plus the reset.
      //
      // Both status filters at once takes some doing: they AND like every other
      // filter, and a mod with no recorded version usually has no update
      // either. The exception is a mod identified by a **banked archive hash**,
      // which can carry an update while its version is unrecorded.
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
      expect(find.text('Library'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_circle_up), findsOneWidget);
      expect(find.byIcon(Icons.priority_high), findsOneWidget);
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

      await runAction(tester, 'Check for updates');

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
      // `Mod/Multi` for one id, not the mod's profile — what the dialog asks
      // for. The record carries current and archived files in one list, so this
      // is also the shape that would catch a reader keying off `_aFiles` rather
      // than `_bIsArchived`.
      transport.stub(
        endpoints.modsMulti(const [531649], updateCheckProperties),
        body: gbMultiRecordFixture(531649),
      );
      // The release feed is fetched alongside the record. RabbitFX's own is
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

    testWidgets('the upload date is a fact about the file, not part of its name',
        (tester) async {
      // It used to be appended to the filename with a dash, which reads as part
      // of the name — `v77.zip — 2026-06-19` looks like a file called that. It
      // belongs on the greyed line with the version and the author's label,
      // which are the same kind of thing.
      await pumpDialog(tester, mod('Ellen', origin: origin(fileId: 1696178)));
      await tester.pumpAndSettle();

      expect(find.text('v77.zip'), findsWidgets);
      expect(find.textContaining('v77.zip — '), findsNothing);
      expect(find.textContaining('uploaded '), findsWidgets);
    });

    testWidgets('a known file states no cutoff, because its date is the row',
        (tester) async {
      // "Compared against <date>" was that same file's upload date under a
      // label that overclaimed: the check reads a mod page's file list and
      // never the mod folder, so *compared* invited the reading that something
      // about the files was.
      await pumpDialog(tester, mod('Ellen', origin: origin(fileId: 1696178)));
      await tester.pumpAndSettle();

      expect(find.text('Compared against'), findsNothing);
      expect(find.text('What counts as new'), findsNothing);
    });

    testWidgets('a date-only install says what the date does', (tester) async {
      // The one path where a date really is the whole of the answer: nothing
      // records which file is installed, so the cutoff is load-bearing — and it
      // says what it does rather than what it is, in the words the resolve
      // dialog uses for the same state.
      await pumpDialog(
        tester,
        mod(
          'Ellen',
          origin: ModOrigin(
            source: 'gamebanana',
            modId: 531649,
            modIdConfidence: OriginConfidence.user,
            versionConfidence: OriginConfidence.assumedLatest,
            provenance: OriginProvenance.downloaded,
            baselineRemoteDate: DateTime.utc(2026, 5, 1),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('What counts as new'), findsOneWidget);
      expect(find.textContaining('counts as an update'), findsOneWidget);
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
      transport.enqueue(
        endpoints.modsMulti(const [531649], updateCheckProperties),
        statusCode: 500,
      );
      transport.stub(
        endpoints.modsMulti(const [531649], updateCheckProperties),
        body: gbMultiRecordFixture(531649),
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

    group('a folder holding two mods', () {
      /// The same fake client, plus the **other** mod in the folder — a second
      /// captured page whose newest file is not the one recorded here.
      (GameBananaClient, FakeHttpTransport) mixedClient({
        bool companionReachable = true,
      }) {
        final transport = FakeHttpTransport();
        final endpoints = GameBananaEndpoints(gameId: 19567);
        transport.stub(
          endpoints.modsMulti(const [531649], updateCheckProperties),
          body: gbMultiRecordFixture(531649),
        );
        transport.stub(
          endpoints.modUpdates(531649),
          body: '{"_aMetadata":{"_nRecordCount":0},"_aRecords":[]}',
        );
        if (companionReachable) {
          // A **separate** request per id, which is the property this group
          // depends on: an unreachable companion must not take the primary's
          // check down with it, and one batch of two would.
          transport.stub(
            endpoints.modsMulti(const [528481], updateCheckProperties),
            body: gbMultiRecordFixture(528481),
          );
          transport.stub(
            endpoints.modUpdates(528481),
            body: '{"_aMetadata":{"_nRecordCount":0},"_aRecords":[]}',
          );
        }
        return (
          GameBananaClient(transport: transport, endpoints: endpoints),
          transport,
        );
      }

      /// A folder whose primary is RabbitFX's newest file — up to date on its
      /// own — with the other mod recorded as a companion.
      ModInfo mixedMod({int? companionFileId = 1258541}) => mod(
            'EllenBikini',
            origin: origin(fileId: 1732269).copyWith(
              companions: [
                ModCompanion(
                  role: CompanionRole.base,
                  modId: 528481,
                  modIdConfidence: OriginConfidence.user,
                  fileId: companionFileId,
                  versionConfidence: companionFileId == null
                      ? OriginConfidence.unknown
                      : OriginConfidence.user,
                ),
              ],
            ),
          );

      testWidgets('the other mod\'s page is fetched too', (tester) async {
        // Without this the fold sees no record for the companion and the
        // dialog reads "nothing may be concluded" — on the one screen the user
        // opened deliberately to find out.
        await tester.pumpWidget(const SizedBox());
        final (client, transport) = mixedClient();
        final target = mixedMod();
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();

        expect(
          transport.requests,
          contains(
            GameBananaEndpoints(gameId: 19567)
                .modsMulti(const [528481], updateCheckProperties),
          ),
          reason: 'the other mod in the folder has to be asked about by name — '
              'a call count would pass on any second request at all, and an id '
              'folded into the primary\'s batch would lose the isolation the '
              'unreachable-companion case depends on',
        );
        // A section each, and the patch is on its newest file — so the finding
        // can only have come from the other mod's record, and the two verdicts
        // sit under their own names rather than one standing for the folder.
        expect(find.text('Possibly outdated'), findsOneWidget);
        expect(find.text('This is the latest file'), findsOneWidget);
      });

      testWidgets('both mods current still names the other one',
          (tester) async {
        // **The reported bug.** With nothing out of date the fold gives the
        // primary's verdict, so the line naming the other mod — which only
        // fires when a companion *wins* — stayed silent, and a folder holding
        // two mods read exactly like a folder holding one. The check had
        // looked at both and said so nowhere.
        await tester.pumpWidget(const SizedBox());
        final (client, _) = mixedClient();
        // A patch installed *into* this folder rather than the reverse, which
        // is the shape the patch installer writes and the direction that had
        // no surface anywhere.
        final target = mod(
          'EllenBikini',
          origin: origin(fileId: 1732269).copyWith(
            companions: [
              const ModCompanion(
                role: CompanionRole.patch,
                modId: 528481,
                modIdConfidence: OriginConfidence.exact,
                // Megalodon Maid Ellen's newest file, so this half is current
                // too and nothing in the folder is out of date.
                fileId: 1462303,
                versionConfidence: OriginConfidence.exact,
              ),
            ],
          ),
        );
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();

        // **A full report each, not a verdict and a footnote.** Both are
        // current, so both say so — under their own names, each with its own
        // before-and-after box.
        expect(find.text('This is the latest file'), findsNWidgets(2));
        expect(find.text('Megalodon Maid Ellen'), findsOneWidget);
        // The folder's own download named by its **mod page**, not by the
        // folder — the check fetched it, so the better name is in hand.
        expect(
          find.text('ZZMI RabbitFX - Glow FX + Censor Remover'),
          findsOneWidget,
        );
        expect(find.text('Mod'), findsOneWidget);
        expect(find.text('Patch'), findsOneWidget);
        expect(find.text('You have'), findsNWidgets(2));
      });

      testWidgets('reopening the dialog does not lose the other mod\'s name',
          (tester) async {
        // **The second open fetches nothing**, because `initState` skips the
        // check when a verdict is already on record — and the verdict it finds
        // is the one the *first* open stored. So the records that named the
        // companion are gone with the disposed widget, and the session map only
        // ever holds what a **bulk** pass banked. A per-mod check banks
        // nothing, so a folder that read "Patched by Megalodon Maid Ellen" came
        // back as "Patched by GameBanana mod #528481".
        final container = ProviderContainer(
          overrides: [
            gameBananaClientProvider.overrideWithValue(mixedClient().$1),
          ],
        );
        addTearDown(container.dispose);

        final target = mod(
          'EllenBikini',
          origin: origin(fileId: 1732269).copyWith(
            companions: [
              const ModCompanion(
                role: CompanionRole.patch,
                modId: 528481,
                modIdConfidence: OriginConfidence.exact,
                fileId: 1462303,
                versionConfidence: OriginConfidence.exact,
              ),
            ],
          ),
        );

        Future<void> open() async {
          await tester.pumpWidget(const SizedBox());
          await pumpLocalized(
            tester,
            ModUpdateDialog(
              mod: target,
              gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
            ),
            container: container,
          );
          await tester.pumpAndSettle();
        }

        await open();
        expect(find.text('Megalodon Maid Ellen'), findsOneWidget);
        // The verdict really was stored, or the second open would just re-check
        // and this would pass for the wrong reason.
        expect(
          container.read(modUpdateChecksProvider)[target.id],
          isNotNull,
        );

        await open();
        expect(find.text('Megalodon Maid Ellen'), findsOneWidget);
        expect(find.textContaining('#528481'), findsNothing);
      });

      testWidgets('a companion page that will not load is not reported clean',
          (tester) async {
        // The primary answered and the other half did not. "Up to date" would
        // be a claim about half a folder.
        await tester.pumpWidget(const SizedBox());
        final (client, _) = mixedClient(companionReachable: false);
        final target = mixedMod();
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();

        // **The unreachable half admits it.** The primary answered and says so
        // in its own section, which is honest; what must not happen is the
        // other section quietly reading as clean on the strength of a request
        // that never landed.
        expect(find.text('The mod page listed no files'), findsOneWidget);
        expect(find.text('This is the latest file'), findsOneWidget);
      });

      testWidgets('an update on the other mod can be installed from here',
          (tester) async {
        // **The write is chosen by which half of the folder it is**, so a
        // verdict about the mod a patch applies to is installable: the base is
        // written by layout and the patch placed back over it. What used to
        // refuse this was the *applier* having only one way to write, not
        // anything about the verdict — see `update_write_route.dart`.
        await tester.pumpWidget(const SizedBox());
        final (client, _) = mixedClient();
        final target = mixedMod();
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();

        expect(find.text('Possibly outdated'), findsOneWidget);
        expect(find.text('Update'), findsOneWidget);
        // Still offered beside it: installing the other mod as a second folder
        // is occasionally what somebody wants.
        expect(find.text('View in marketplace'), findsOneWidget);
      });


      testWidgets('an update on this mod is still applied normally',
          (tester) async {
        // The guard must key on *whose* finding it is, not on the folder having
        // a companion at all — otherwise naming the other mod would silently
        // disable updating the mod you actually installed.
        await tester.pumpWidget(const SizedBox());
        final (client, _) = mixedClient();
        // The primary is on an archived file, so the finding is the patch's
        // own; the companion is on its newest and has nothing to report.
        final target = mod(
          'EllenBikini',
          origin: origin(fileId: 1696178).copyWith(
            companions: [
              const ModCompanion(
                role: CompanionRole.base,
                modId: 528481,
                modIdConfidence: OriginConfidence.user,
                fileId: 1462303,
                versionConfidence: OriginConfidence.user,
              ),
            ],
          ),
        );
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();

        expect(find.text('An update is available'), findsOneWidget);
        expect(find.text('Update'), findsOneWidget);
      });

      testWidgets('ignoring a companion\'s update writes it on the companion',
          (tester) async {
        // Written on the primary it silences nothing — the companion carries
        // its own dismissal — and stamps another mod's release date onto this
        // folder's block.
        await tester.pumpWidget(const SizedBox());
        final (client, _) = mixedClient();
        final target = mixedMod();
        final written = <ModOrigin?>[];
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, written),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();
        // In the companion's own section now, not the shared action bar — so it
        // can be below the fold on a folder rendering two full reports.
        await tester.ensureVisible(find.text('Ignore this update'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ignore this update'));
        await tester.pumpAndSettle();

        final block = written.single!;
        expect(block.updatesDismissedUntil, isNull,
            reason: 'the folder\'s own releases were never in question');
        expect(block.companions.single.updatesDismissedUntil, isNotNull);
      });

      testWidgets('an unnamed patch still says only the patch is tracked',
          (tester) async {
        // The shipped half, unchanged: with no companion named there is
        // nothing to fetch and nothing to fold, and the folder gets the
        // admission rather than a clean bill.
        await tester.pumpWidget(const SizedBox());
        final (client, _) = mixedClient();
        final target = mod(
          'EllenBikini',
          origin: origin(fileId: 1732269)
              .copyWith(ingest: const ModIngest(patchShaped: true)),
        );
        await pumpLocalized(
          tester,
          ModUpdateDialog(
            mod: target,
            gateway: _RecordingGateway(target.origin, <ModOrigin?>[]),
          ),
          overrides: [gameBananaClientProvider.overrideWithValue(client)],
        );
        await tester.pumpAndSettle();

        expect(find.text('Only the patch is tracked here'), findsOneWidget);
      });
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
