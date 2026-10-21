import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/screens/components/shader_fixes_notices.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_plan.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';
import 'package:mod_manager_flutter/utils/state_providers.dart';

import 'support/localized_harness.dart';

/// **A shader refusal says whose files are in the way, as they are.** Another copy of the mod is not named as
/// another mod, and a link is not described as different contents.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations loc;

  setUpAll(() async {
    loc = AppLocalizations(const Locale('en'));
    await loc.load();
  });

  String bodyOf(ShaderPlacementRefused refusal) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    reportShaderRefusal(loc, container.read(notificationsProvider.notifier), refusal);
    return container.read(notificationsProvider).single.body;
  }

  const file = '1f6ab42231416fdb-vs_replace.txt';

  test('files another copy of the mod placed name it as a copy in a folder that cannot be read', () {
    final body = bodyOf(const ShaderPlacementRefused.conflicts('Jiggle', [ShaderConflict(file, 'Jiggle', ownerUid: 'old')]));

    expect(body, loc.t('mods.shader_fixes.taken_copy_body', params: {'mod': 'Jiggle', 'files': file}));
  });

  test('files of a copy another link keeps on name that link', () {
    final body = bodyOf(const ShaderPlacementRefused.conflicts('Jiggle', [ShaderConflict(file, 'Jiggle', ownerUid: 'old')])
        .stillOnThrough('old', 'Jiggle by hand'));

    expect(body, loc.t('mods.shader_fixes.taken_still_on_body',
        params: {'mod': 'Jiggle', 'files': file, 'link': 'Jiggle by hand'}));
  });

  test('a link in the way is called a link', () {
    final body = bodyOf(const ShaderPlacementRefused.conflicts('Jiggle', [ShaderConflict(file, null, link: true)]));

    expect(body, loc.t('mods.shader_fixes.taken_link_body', params: {'mod': 'Jiggle', 'files': file}));
  });

  test('no shader folder offers Open Settings, where the ZZMI folder is chosen', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    reportShaderRefusal(loc, container.read(notificationsProvider.notifier),
        const ShaderPlacementRefused.noShaderFolder('Jiggle'), container: container);

    final action = container.read(notificationsProvider).single.actions.single;
    expect(action.label, 'Open Settings');
    action.onPressed();
    expect(container.read(destinationProvider), AppDestination.settings);
  });

  testWidgets("another copy's files that could not be put back offer Open folder", (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpLocalized(tester, const ShaderRestartNoticeHost(child: SizedBox()), container: container);

    ShaderFixesService.reportShortfall(const ShaderRestoreShortfall('Jiggle', '/library/Jiggle', [file]));
    await tester.pump();

    final card = container.read(notificationsProvider).single;
    expect(card.title, 'Shader files not put back');
    expect(card.actions.map((a) => a.label), ['Open folder']);
    await tester.pump(const Duration(seconds: 9));
  });
}
