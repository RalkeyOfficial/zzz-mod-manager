/// The unpacks running right now and what each still has to write, for the unpack's space check.
///
/// A drop, a background install and an update can unpack at once, and each check reads the free space at its own instant, so two that each fit can pass together and jointly fill the temp folder, a tmpfs on most Linux desktops.
/// The check adds what the others still have to write, as the transfer's check adds what the other transfers still have to fetch (`docs/downloads.md` §4.1).
///
/// An unpacked folder that is waiting (an install question, the drop's next step) is not counted: its bytes are on the volume already, so the free space a check reads has them taken off.
///
/// A plain static [shared] rather than a provider, for the reason `ArchiveActivity` gives: `ArchiveService` is a static service with no `ref`.
library;

import 'dart:io';

import '../utils/directory_size.dart';
import '../utils/serial_queue.dart';

class UnpacksInFlight {
  /// [written] measures what an unpack's folder holds so far; a walk of the folder by default.
  UnpacksInFlight({Future<int> Function(Directory into)? written}) : _written = written ?? _measure;

  /// The one every unpack registers with.
  static final UnpacksInFlight shared = UnpacksInFlight();

  final Future<int> Function(Directory into) _written;
  final Map<int, ({int bytes, Directory into})> _running = {};
  final SerialQueue _checks = SerialQueue();
  int _nextId = 0;

  int get count => _running.length;

  /// What the unpacks in flight still have to write, together: each one's listed size less what its folder holds.
  Future<int> stillToWrite() async {
    var total = 0;
    for (final unpack in _running.values.toList()) {
      final left = unpack.bytes - await _written(unpack.into);
      if (left > 0) total += left;
    }
    return total;
  }

  /// Runs [body] alone among the callers of this, so a check and the [begin] it leads to are one step: two checks that ran side by side would each miss the other.
  Future<T> serialised<T>(Future<T> Function() body) => _checks.run(body);

  /// Registers an unpack of [bytes] into [into]. The function returned ends it, and is safe to call twice.
  void Function() begin(int bytes, Directory into) {
    final id = _nextId++;
    _running[id] = (bytes: bytes, into: into);
    return () => _running.remove(id);
  }

  static Future<int> _measure(Directory into) async => (await measureDirectory(into.path)).bytes;
}
