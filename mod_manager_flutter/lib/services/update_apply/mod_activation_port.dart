import '../mod_manager_service.dart';
import 'update_applier.dart';

/// The real [ModActivationPort], over `ModManagerService`.
///
/// Three lines with no logic in them, and that is the point: the applier holds
/// the ordering rule (deactivate for open handles, put the mod back exactly as
/// it was) and this holds nothing, so a test can substitute a recorder without
/// reaching `ApiService`'s singletons and the developer's real `config.json`.
class ModManagerActivationPort implements ModActivationPort {
  const ModManagerActivationPort(this._mods);

  final ModManagerService _mods;

  @override
  Future<bool> isActive(String modName) => _mods.isModActive(modName);

  @override
  Future<bool> activate(String modName) => _mods.activateMod(modName);

  @override
  Future<bool> deactivate(String modName) => _mods.deactivateMod(modName);
}
