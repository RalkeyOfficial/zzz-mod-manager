import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mod_manager_flutter/l10n/app_localizations.dart';
import 'package:mod_manager_flutter/screens/components/shader_fixes_notices.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_plan.dart';
import 'package:mod_manager_flutter/services/shader_fixes/shader_fixes_service.dart';
import 'package:mod_manager_flutter/utils/notifications.dart';

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
}
