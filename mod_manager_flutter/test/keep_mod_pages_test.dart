import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/gamebanana/gb_mod.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

/// A page fetched outside the whole-library check replaces the check's record of it and the page fetched before it,
/// unless it is the older read: a mod's page goes through the response cache, which the check bypasses.
void main() {
  final v1 = DateTime.utc(2026, 10, 1);
  final v2 = DateTime.utc(2026, 10, 15);

  GbMod page(String name, DateTime uploaded, {DateTime? updated}) => GbMod(
        idRow: 1,
        name: name,
        dateUpdated: updated ?? uploaded,
        files: [GbFile(idRow: uploaded.day, dateAdded: uploaded)],
      );

  /// Keeps [fetched] the way a mod's page does, over a check that holds [record], or over [earlier] fetched before.
  Future<ProviderContainer> keepOver(WidgetTester tester, GbMod? record, GbMod fetched, {GbMod? earlier}) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    if (record != null) container.read(modUpdateRecordsProvider.notifier).state = {1: record};
    if (earlier != null) container.read(fetchedModPagesProvider.notifier).state = {1: earlier};
    late WidgetRef widgetRef;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (_, ref, __) {
        widgetRef = ref;
        return const SizedBox();
      }),
    ));
    keepModPages(widgetRef, {1: fetched});
    return container;
  }

  testWidgets("a cached page older than the check's doesn't replace its record", (tester) async {
    final container = await keepOver(tester, page('v2', v2), page('v1', v1));

    expect(container.read(modUpdateRecordsProvider)[1]?.name, 'v2');
    expect(container.read(knownModPagesProvider)[1]?.name, 'v2', reason: 'the card and the details panel show v2');
  });

  testWidgets('a page with an older last update but no older file still loses', (tester) async {
    final container = await keepOver(tester, page('checked', v1, updated: v2), page('cached', v1));

    expect(container.read(modUpdateRecordsProvider)[1]?.name, 'checked');
  });

  testWidgets('a newer page replaces the record', (tester) async {
    final container = await keepOver(tester, page('v1', v1), page('v2', v2));

    expect(container.read(modUpdateRecordsProvider)[1]?.name, 'v2');
  });

  testWidgets('a page of the same age replaces the record', (tester) async {
    final container = await keepOver(tester, page('Old title', v1), page('New title', v1));

    expect(container.read(modUpdateRecordsProvider)[1]?.name, 'New title');
  });

  testWidgets("a cached page older than one fetched before doesn't replace it", (tester) async {
    // A check of the ticked mods fetched v2; the mod's page then reads v1 from the cache.
    final container = await keepOver(tester, null, page('v1', v1), earlier: page('v2', v2));

    expect(container.read(fetchedModPagesProvider)[1]?.name, 'v2');
    expect(container.read(knownModPagesProvider)[1]?.name, 'v2');
    expect(container.read(modUpdateRecordsProvider), isEmpty, reason: 'no record for a mod the check did not reach');
  });

  testWidgets('a newer page replaces one fetched before', (tester) async {
    final container = await keepOver(tester, null, page('v2', v2), earlier: page('v1', v1));

    expect(container.read(fetchedModPagesProvider)[1]?.name, 'v2');
  });
}
