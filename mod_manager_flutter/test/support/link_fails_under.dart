import 'dart:io';

import 'package:mod_manager_flutter/services/platform_service_linux.dart';
import 'package:path/path.dart' as p;

/// Links as Linux makes them, except one under [name], which fails after a file is put at [occupying], so a folder
/// renamed away from there can't be renamed back: a rename left off under its new name.
class LinkFailsUnder extends LinuxPlatformService {
  LinkFailsUnder(this.name);

  final String name;
  String? occupying;

  @override
  Future<bool> createModLink(String source, String linkPath) async {
    if (p.basename(linkPath) != name) return super.createModLink(source, linkPath);
    File(occupying!).createSync();
    return false;
  }
}
