import 'dart:typed_data';

/// The reparse tag of a junction (a mount point).
const int ioReparseTagMountPoint = 0xA0000003;

/// `ReparseTag`, `ReparseDataLength` and `Reserved`, ahead of the tag's own data.
const int reparseDataHeaderSize = 8;

/// `MAXIMUM_REPARSE_DATA_BUFFER_SIZE`: the most one reparse point can hold, header included.
const int maximumReparseDataBufferSize = 16 * 1024;

/// The `REPARSE_DATA_BUFFER` that makes a folder a junction to [target], an absolute path such as `C:\Mods\Ellen`.
///
/// Laid out as `MountPointReparseBuffer`, little-endian: the tag, the length of everything after the header, a
/// reserved zero, then the offset and length in bytes of the substitute name and of the print name within the path
/// buffer, each length without its terminating NUL. The path buffer holds the substitute name `\??\<target>` and
/// then the print name `<target>`, each NUL-terminated UTF-16. A `\\?\` prefix on [target] is dropped first, since
/// the substitute name carries its own. Throws an [ArgumentError] when the names don't fit in one reparse point.
Uint8List mountPointReparseBuffer(String target) {
  final printName = target.startsWith(r'\\?\') ? target.substring(4) : target;
  final substituteName = '\\??\\$printName';
  final substituteBytes = substituteName.length * 2;
  final printBytes = printName.length * 2;
  // The four offset and length fields, then both names with their NULs.
  final dataLength = 8 + substituteBytes + 2 + printBytes + 2;
  if (reparseDataHeaderSize + dataLength > maximumReparseDataBufferSize) {
    throw ArgumentError.value(target, 'target', 'too long for a junction');
  }

  final bytes = Uint8List(reparseDataHeaderSize + dataLength);
  final data = ByteData.sublistView(bytes);
  data.setUint32(0, ioReparseTagMountPoint, Endian.little);
  data.setUint16(4, dataLength, Endian.little);
  data.setUint16(6, 0, Endian.little);
  data.setUint16(8, 0, Endian.little);
  data.setUint16(10, substituteBytes, Endian.little);
  data.setUint16(12, substituteBytes + 2, Endian.little);
  data.setUint16(14, printBytes, Endian.little);
  var offset = 16;
  for (final name in [substituteName, printName]) {
    for (final unit in name.codeUnits) {
      data.setUint16(offset, unit, Endian.little);
      offset += 2;
    }
    // The NUL is already there: the buffer starts zeroed.
    offset += 2;
  }
  return bytes;
}
