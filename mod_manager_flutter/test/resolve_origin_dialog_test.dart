import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/character_info.dart';
import 'package:mod_manager_flutter/models/mod_origin.dart';
import 'package:mod_manager_flutter/models/origin_enums.dart';
import 'package:mod_manager_flutter/screens/dialogs/resolve_origin_dialog.dart';
import 'package:mod_manager_flutter/services/gamebanana/gamebanana_client.dart';
import 'package:mod_manager_flutter/services/gamebanana/remote_mod_metadata.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/fake_http_transport.dart';
import 'support/fixtures.dart';
import 'support/localized_harness.dart';

/// Records what the dialog would have done locally, and touches nothing.
///
/// The real gateway goes through `ApiService`, which lazily builds a
/// `ConfigService` that writes the developer's actual `<appData>/config.json` —
/// so a test using it would clobber their library paths and favourites just by
/// mounting the widget.
class _FakeGateway implements ResolveOriginGateway {
  _FakeGateway({this.probe, this.result = true, this.current});

  final DateTime? probe;
  final bool result;

  /// The block "on disk" the write path hands to the update function. Set it
  /// to something other than what the dialog was opened with to stand in for a
  /// sidecar rewritten while the dialog was up.
  final ModOrigin? current;

  int probeCalls = 0;
  int writes = 0;
  ModOrigin? written;
  bool abandoned = false;
  final List<String> filled = [];

  @override
  Future<DateTime?> installDateProxy(String modId) async {
    probeCalls++;
    return probe;
  }

  @override
  Future<bool> writeOrigin(
    String modId,
    ModOrigin? Function(ModOrigin? current) update,
  ) async {
    writes++;
    written = update(current);
    abandoned = written == null;
    return result && written != null;
  }

  @override
  Future<void> fillMetadata(String modId, RemoteModMetadata remote) async {
    filled.add(modId);
  }
}

/// Stands in for a `SocketException` without importing `dart:io` into a widget
/// test — the client only cares that the transport threw.
class _TransportFailure implements Exception {
  const _TransportFailure();
}

void main() {
  final profileUrl =
      Uri.parse('https://gamebanana.com/apiv11/Mod/531649/ProfilePage');
  final searchUrl = Uri.parse(
    'https://gamebanana.com/apiv11/Util/Search/Results'
    '?_sModelName=Mod&_sSearchString=Ellen%20Swimsuit&_idGameRow=19567&_nPage=1',
  );

  ModInfo mod({ModOrigin? origin, String name = 'RabbitFX'}) => ModInfo(
        id: name,
        name: name,
        characterId: 'unknown',
        isActive: false,
        origin: origin,
      );

  ModOrigin tracked({
    int modId = 531649,
    String? archiveMd5,
    DateTime? installedAt,
    OriginConfidence modIdConfidence = OriginConfidence.inferred,
    OriginTracking tracking = OriginTracking.auto,
    int? fileId,
    String? version,
    String? versionLabel,
    OriginConfidence versionConfidence = OriginConfidence.unknown,
    OriginProvenance provenance = OriginProvenance.importedFolder,
    DateTime? baselineRemoteDate,
  }) =>
      ModOrigin(
        source: 'gamebanana',
        modId: modId,
        modIdConfidence: modIdConfidence,
        provenance: provenance,
        installedAt: installedAt,
        archiveMd5: archiveMd5,
        tracking: tracking,
        fileId: fileId,
        version: version,
        versionLabel: versionLabel,
        versionConfidence: versionConfidence,
        baselineRemoteDate: baselineRemoteDate,
      );

  /// Mounts the dialog with a scripted transport. Nothing here reaches a
  /// network or a filesystem.
  Future<_FakeGateway> pumpDialog(
    WidgetTester tester, {
    required ModInfo target,
    FakeHttpTransport? transport,
    _FakeGateway? gateway,
  }) async {
    // Written out rather than as `transport ?? FakeHttpTransport()..stub(...)`:
    // a cascade binds looser than `??`, so that form silently stubs a
    // caller-supplied transport too.
    final http = transport ??
        (FakeHttpTransport()
          ..stub(profileUrl, body: loadGbFixture('mod_profile_531649')));
    // Unless a test is standing in for a sidecar rewritten mid-dialog, what the
    // write path reads back off disk is what the mod already carried.
    final fake = gateway ?? _FakeGateway(current: target.origin);
    await pumpLocalized(
      tester,
      ResolveOriginDialog(mod: target, gateway: fake),
      overrides: [
        gameBananaClientProvider.overrideWithValue(
          GameBananaClient(transport: http, maxRetries: 0),
        ),
      ],
    );
    return fake;
  }

  group('a mod whose identity is already known', () {
    testWidgets('lists every published file with a stated reason',
        (tester) async {
      await pumpDialog(
        tester,
        target: mod(origin: tracked(installedAt: DateTime.utc(2026, 5, 8, 14))),
      );
      expectBuilt(ResolveOriginDialog);

      // The mod page's name, so the identity card really resolved.
      expect(find.textContaining('RabbitFX'), findsWidgets);
      // Current files and archived ones both, because an old install matches a
      // superseded file far more often than the current one.
      expect(find.text('Main file'), findsWidgets);
      expect(find.text('Glow demo'), findsOneWidget);
      // Ranked *and* explained — a ranking with no visible reason cannot be
      // argued with.
      expect(
        find.text('newest file that existed when you installed this'),
        findsOneWidget,
      );
    });

    testWidgets('a banked hash settles it and says so', (tester) async {
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(archiveMd5: '18b741db96df8c640d7c897681c5e478'),
        ),
      );
      expect(find.text('byte-identical to your archive'), findsOneWidget);
      // Phrased as a match, never as verification: md5 is a matching key only.
      expect(find.textContaining('byte-identical to this file'), findsOneWidget);
      expect(find.textContaining('verified'), findsNothing);
    });

    testWidgets('saving a hash-matched pick writes exact confidence',
        (tester) async {
      final gateway = await pumpDialog(
        tester,
        target: mod(
          origin: tracked(archiveMd5: '18b741db96df8c640d7c897681c5e478'),
        ),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(gateway.writes, 1);
      expect(gateway.written!.fileId, 1695165);
      expect(gateway.written!.version, '7.3');
      expect(gateway.written!.versionLabel, 'Main file');
      expect(gateway.written!.versionConfidence, OriginConfidence.exact);
      // Confirming an inferred identity raises it — it came from a free-form
      // field a human typed, and this is the human saying yes.
      expect(gateway.written!.modIdConfidence, OriginConfidence.user);
    });

    testWidgets('identity and file are one write, not two', (tester) async {
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked()),
      );
      await tester.tap(find.text('Main file').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(gateway.writes, 1);
      expect(gateway.written!.versionConfidence, OriginConfidence.user);
    });

    testWidgets('abandons rather than binding a file to the wrong mod',
        (tester) async {
      // The sidecar was rebound to a different mod while the dialog was open.
      // The transform sees what is on disk now, and must decline.
      final gateway = _FakeGateway(current: tracked(modId: 999));
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(modIdConfidence: OriginConfidence.user),
        ),
        gateway: gateway,
      );
      await tester.tap(find.text('Main file').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(gateway.abandoned, isTrue);
      // Still open, with a warning — the dialog does not report success.
      expect(find.byType(ResolveOriginDialog), findsOneWidget);
    });

    testWidgets('"I don\'t know which" needs no file and records a baseline',
        (tester) async {
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked(installedAt: DateTime.utc(2026, 3, 1))),
      );
      await tester.tap(find.text("I don't know which file"));
      await tester.pumpAndSettle();

      expect(gateway.written!.versionConfidence, OriginConfidence.assumedLatest);
      expect(gateway.written!.baselineRemoteDate, DateTime.utc(2026, 3, 1));
      expect(gateway.written!.fileId, isNull);
    });

    testWidgets('the assumed baseline is clamped to the mod\'s own age',
        (tester) async {
      // A hand-copied library keeps the author's build timestamps, so the proxy
      // install date can predate the mod itself — unclamped, that flags every
      // file it ever published. The fixture's mod was created 2024-07-29.
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked(installedAt: DateTime.utc(2019))),
      );
      await tester.tap(find.text("I don't know which file"));
      await tester.pumpAndSettle();

      expect(gateway.written!.baselineRemoteDate!.year, 2024);
    });

    testWidgets('"not from GameBanana" silences it without erasing identity',
        (tester) async {
      final gateway = await pumpDialog(tester, target: mod(origin: tracked()));
      await tester.tap(find.text("Not from GameBanana, or it's my own"));
      await tester.pumpAndSettle();

      expect(gateway.written!.tracking, OriginTracking.off);
      // Kept so turning it back on is an undo rather than a second trip
      // through the dialog.
      expect(gateway.written!.modId, 531649);
    });

    testWidgets('a failed write says so instead of closing quietly',
        (tester) async {
      // A read-only mod folder or an odd network share. Closing on a failed
      // write would leave the user believing the mod is tracked when nothing
      // was recorded — and nothing re-attempts this write.
      final gateway = _FakeGateway(current: tracked(), result: false);
      await pumpDialog(
        tester,
        target: mod(origin: tracked()),
        gateway: gateway,
      );
      await tester.tap(find.text('Main file').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(ResolveOriginDialog), findsOneWidget);
      expect(find.textContaining('may be read-only'), findsOneWidget);
    });

    testWidgets('"it\'s my own" survives the mod page being unreachable',
        (tester) async {
      // The hatch is a statement about the folder, so it needs nothing from the
      // network. "Assume current" is deliberately absent here instead — its
      // baseline is clamped against the mod's creation date, which is exactly
      // the field that just failed to arrive.
      final transport = FakeHttpTransport()
        ..enqueueError(profileUrl, const _TransportFailure());
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked()),
        transport: transport,
      );

      expect(find.textContaining("Couldn't reach GameBanana"), findsOneWidget);
      expect(find.text("I don't know which file"), findsNothing);

      await tester.tap(find.text("Not from GameBanana, or it's my own"));
      await tester.pumpAndSettle();
      expect(gateway.written!.tracking, OriginTracking.off);
    });

    testWidgets('"Change" drops back to a search that has already run',
        (tester) async {
      // Not an empty box with the folder name already typed into it — that
      // reads as a control that did nothing.
      final transport = FakeHttpTransport()
        ..stub(profileUrl, body: loadGbFixture('mod_profile_531649'))
        ..stub(
          Uri.parse(
            'https://gamebanana.com/apiv11/Util/Search/Results'
            '?_sModelName=Mod&_sSearchString=RabbitFX&_idGameRow=19567&_nPage=1',
          ),
          body: loadGbFixture('search_ellen'),
        );
      await pumpDialog(
        tester,
        target: mod(origin: tracked()),
        transport: transport,
      );

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      expect(find.text('Which mod is this?'), findsOneWidget);
      expect(
        transport.requests.where((u) => u.path.contains('Search')),
        hasLength(1),
      );
    });

    testWidgets('"it\'s my own" does not pull data off the page it disowns',
        (tester) async {
      // The checkbox sits above the hatch in the same column, so ticking it and
      // then answering "not from GameBanana" is ordinary. Honouring both would
      // write that page's description and gallery into a mod the user has just
      // said isn't from there.
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked()),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Not from GameBanana, or it's my own"));
      await tester.pumpAndSettle();

      expect(gateway.written!.tracking, OriginTracking.off);
      expect(gateway.filled, isEmpty);
    });

    testWidgets('Save is dead when there is nothing left to record',
        (tester) async {
      // Identity already confirmed, no file picked: saving would write the
      // block back byte-for-byte and trigger a rescan, which reads as an action.
      final gateway = await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            modIdConfidence: OriginConfidence.user,
            installedAt: DateTime.utc(2026, 3, 1),
          ),
        ),
      );
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save.onPressed, isNull);

      await tester.tap(find.text('Main file').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(gateway.writes, 1);
    });

    testWidgets('the metadata fill stays off unless it is asked for',
        (tester) async {
      final gateway = await pumpDialog(
        tester,
        target:
            mod(origin: tracked(archiveMd5: '18b741db96df8c640d7c897681c5e478')),
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(gateway.filled, isEmpty);
    });

    testWidgets('ticking the box fills what the mod is missing', (tester) async {
      final gateway = await pumpDialog(
        tester,
        target:
            mod(origin: tracked(archiveMd5: '18b741db96df8c640d7c897681c5e478')),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(gateway.filled, ['RabbitFX']);
    });
  });

  group('what is already tracked', () {
    // The reported gap: the dialog could not state its own subject's answer. It
    // read `mod_id` to know what to fetch and `installed_at` to rank files, and
    // never read `file_id`, `version_confidence` or `baseline_remote_date` at
    // all — so a mod resolved months ago opened looking exactly like one never
    // touched, and a library could only be told apart one dialog at a time.

    testWidgets('a date-only mod says so, and quotes the recorded baseline',
        (tester) async {
      // Not the install date: `assumeCurrent` clamps the stored baseline to the
      // mod's creation date, so the two legitimately differ and quoting the
      // derived one would state a cutoff that is not in force.
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            installedAt: DateTime.utc(2024, 1, 1),
            baselineRemoteDate: DateTime.utc(2026, 6, 29),
            versionConfidence: OriginConfidence.assumedLatest,
          ),
        ),
      );
      expect(find.textContaining('No file recorded'), findsOneWidget);
      expect(find.textContaining('2026-06-29'), findsWidgets);
      expect(find.textContaining('2024-01-01'), findsNothing);
    });

    testWidgets('a chosen file is named, marked on its row, and preselected',
        (tester) async {
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            fileId: 1492636,
            versionLabel: 'Glow demo',
            versionConfidence: OriginConfidence.user,
          ),
        ),
      );
      // Stated at the top...
      expect(find.textContaining('the file you chose'), findsOneWidget);
      // ...marked on the row it refers to...
      expect(find.text('on record'), findsOneWidget);
      // ...and selected, so the answer is visible rather than merely available.
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    });

    testWidgets('the two routes to exact are worded differently',
        (tester) async {
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            fileId: 1492636,
            versionConfidence: OriginConfidence.exact,
            provenance: OriginProvenance.downloaded,
          ),
        ),
      );
      expect(find.textContaining('the file you downloaded'), findsOneWidget);
      // A checksum match is a match, never verification — so it must not borrow
      // the wording of having obtained the file.
      expect(find.textContaining('byte-identical'), findsNothing);
    });

    testWidgets('an unconfirmed identity is labelled as one', (tester) async {
      await pumpDialog(tester, target: mod(origin: tracked()));
      expect(find.textContaining('not confirmed'), findsOneWidget);
    });

    testWidgets('Save is dead when the preselected row is what is recorded',
        (tester) async {
      // The recorded row being preselected makes Save live the instant the
      // dialog opens; pressing it would rewrite the block byte-for-byte, close,
      // and trigger a rescan, which reads as though it did something.
      //
      // The block has to match the file *completely* for that to be true —
      // including the variant label, which is what `_sDescription` carries.
      // A record missing it is genuinely improvable, and Save stays live.
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            fileId: 1492636,
            versionLabel: 'Glow demo',
            modIdConfidence: OriginConfidence.user,
            versionConfidence: OriginConfidence.user,
          ),
        ),
      );
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save.onPressed, isNull);
    });

    testWidgets('re-saving a downloaded file does not demote it to a guess',
        (tester) async {
      // `exact` is the tier that gates unattended updates, and picking a row
      // records `user` unless a hash matched — so confirming what we downloaded
      // would have *lowered* it. Harmless while nothing preselected the recorded
      // row; with the fix above, pressing Save was enough.
      final gateway = await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            fileId: 1492636,
            versionLabel: 'Glow demo',
            modIdConfidence: OriginConfidence.inferred,
            versionConfidence: OriginConfidence.exact,
            provenance: OriginProvenance.downloaded,
          ),
        ),
      );
      // Identity is still `inferred`, so there is a real change to save.
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(gateway.written?.versionConfidence, OriginConfidence.exact);
      expect(gateway.written?.modIdConfidence, OriginConfidence.user);
    });

    testWidgets('re-picking a guessed row upgrades it to a confirmed one',
        (tester) async {
      // The other direction: `inferred` is waiting for exactly this, so the
      // no-demotion rule must not freeze a weak tier in place.
      final gateway = await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            fileId: 1492636,
            versionLabel: 'Glow demo',
            modIdConfidence: OriginConfidence.user,
            versionConfidence: OriginConfidence.inferred,
          ),
        ),
      );
      await tester.tap(find.text('Glow demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(gateway.written?.versionConfidence, OriginConfidence.user);
    });

    testWidgets('changing the mod stops describing the old one', (tester) async {
      // After "Change" the card names a different mod, while the recorded file,
      // version and baseline still belong to the previous one — showing them
      // under the new name would attribute one mod's history to another.
      await pumpDialog(
        tester,
        target: mod(
          origin: tracked(
            fileId: 1492636,
            versionLabel: 'Glow demo',
            versionConfidence: OriginConfidence.user,
          ),
        ),
      );
      expect(find.textContaining('the file you chose'), findsOneWidget);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      expect(find.textContaining('the file you chose'), findsNothing);
    });
  });

  group('a mod with no identity', () {
    testWidgets('searches for the folder name and probes an install date',
        (tester) async {
      final transport = FakeHttpTransport()
        ..stub(searchUrl, body: loadGbFixture('search_ellen'))
        ..stub(profileUrl, body: loadGbFixture('mod_profile_531649'));
      final gateway = _FakeGateway(probe: DateTime.utc(2025, 1, 1));

      await pumpDialog(
        tester,
        target: mod(name: 'Ellen Swimsuit'),
        transport: transport,
        gateway: gateway,
      );

      expect(find.text('Which mod is this?'), findsOneWidget);
      expect(find.text('Ellen Swimsuit'), findsWidgets);
      // The backfill only walks folders it can recover an identity for, so a mod
      // that never had a source_url has no install date until this probe.
      expect(gateway.probeCalls, 1);
    });

    testWidgets('a pasted file link says why it cannot work', (tester) async {
      // Probed against the live API: neither apiv11 nor the legacy Core API
      // exposes the mod a file belongs to, so this is a dead end however it is
      // dressed up. Saying so beats searching for the url as if it were a name.
      await pumpDialog(tester, target: mod(name: 'Ellen Swimsuit'));

      await tester.enterText(
        find.byType(TextField),
        'https://gamebanana.com/dl/1701141',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('points at a file, not at a mod page'),
        findsOneWidget,
      );
    });

    testWidgets('a pasted mod page resolves without searching', (tester) async {
      final transport = FakeHttpTransport()
        ..stub(searchUrl, body: loadGbFixture('search_ellen'))
        ..stub(profileUrl, body: loadGbFixture('mod_profile_531649'));

      await pumpDialog(
        tester,
        target: mod(name: 'Ellen Swimsuit'),
        transport: transport,
      );
      await tester.enterText(
        find.byType(TextField),
        'https://gamebanana.com/mods/531649',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.text('Which file do you have?'), findsOneWidget);
      // The url went to the profile endpoint, not into the search box's query —
      // searching for a url as if it were a mod name finds nothing.
      expect(
        transport.requests.where((u) => '$u'.contains('gamebanana.com%2Fmods')),
        isEmpty,
      );
    });

    testWidgets('"not from GameBanana" is reachable with no identity at all',
        (tester) async {
      // The single most common honest answer for a legacy library, so it cannot
      // be gated behind finding a mod page first.
      final gateway = await pumpDialog(tester, target: mod(name: 'my own thing'));
      await tester.tap(find.text("Not from GameBanana, or it's my own"));
      await tester.pumpAndSettle();

      expect(gateway.written!.tracking, OriginTracking.off);
    });
  });

  group('a mod the user declared their own', () {
    testWidgets('offers to resume rather than re-asking', (tester) async {
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked(tracking: OriginTracking.off)),
      );
      expect(find.text('Which file do you have?'), findsNothing);

      await tester.tap(find.text('Track this mod again'));
      await tester.pumpAndSettle();
      expect(gateway.written!.tracking, OriginTracking.auto);
    });

    testWidgets('fetches nothing it could never show', (tester) async {
      // The whole view is one notice and one button; a mod page cannot fill in
      // any of it, so the request would be a round trip for nothing. The probe
      // is a folder walk for the same nothing.
      final transport = FakeHttpTransport()
        ..stub(profileUrl, body: loadGbFixture('mod_profile_531649'));
      final gateway = await pumpDialog(
        tester,
        target: mod(origin: tracked(tracking: OriginTracking.off)),
        transport: transport,
      );

      expect(transport.requests, isEmpty);
      expect(gateway.probeCalls, 0);
    });
  });
}
