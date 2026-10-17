import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The bundled fonts and their SIL Open Font License files, which must ship with them.
const _fontLicenses = {
  'Geist': 'assets/fonts/geist/OFL.txt',
  'Geist Mono': 'assets/fonts/geist-mono/OFL.txt',
  'Unbounded': 'assets/fonts/unbounded/OFL.txt',
};

/// Adds the fonts' licences to the app's licence page. Read lazily, only when that page asks.
void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final MapEntry(key: family, value: path) in _fontLicenses.entries) {
      yield LicenseEntryWithLineBreaks([family], await rootBundle.loadString(path));
    }
  });
}
