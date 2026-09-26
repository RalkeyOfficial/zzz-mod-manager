import '../log/logger.dart';
import '../mod_manager_service.dart';
import '../shader_fixes/shader_fixes_service.dart';
import 'update_applier.dart';

final Logger _log = Logger('mods');

/// The real [ModActivationPort], over `ModManagerService`.
///
/// Holds no logic, and that is the point: the applier holds the ordering rule
/// (deactivate for open handles, put the mod back exactly as it was) and this
/// holds nothing, so a test can substitute a recorder without reaching
/// `ApiService`'s singletons and the developer's real `config.json`.
///
/// A refused shader placement reads as a failed activation: it comes after the
/// folder is written, where an exception would abandon the rest of the result.
/// The refusal itself is reported for the notice host to show, since the mod was
/// on before and is off now.
class ModManagerActivationPort implements ModActivationPort {
  const ModManagerActivationPort(this._mods);

  final ModManagerService _mods;

  @override
  Future<bool> isActive(String modName) => _mods.isModActive(modName);

  @override
  Future<bool> activate(String modName) async {
    try {
      return await _mods.activateMod(modName);
    } on ShaderPlacementRefused catch (refusal) {
      _log.warning('mod left off after writing, shader files refused',
          error: refusal, fields: {'mod': modName});
      ShaderFixesService.reportUnattended(refusal);
      return false;
    }
  }

  @override
  Future<bool> deactivate(String modName) => _mods.deactivateMod(modName);
}
