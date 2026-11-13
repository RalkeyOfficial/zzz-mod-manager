import 'dart:io';

import 'package:mod_manager_flutter/models/gamebanana/gb_file.dart';
import 'package:mod_manager_flutter/models/mod_download.dart';
import 'package:mod_manager_flutter/services/download/download_handle.dart';
import 'package:mod_manager_flutter/services/download/download_job.dart';
import 'package:mod_manager_flutter/services/download/download_request.dart';
import 'package:mod_manager_flutter/services/download/update_job.dart';

const int mb = 1024 * 1024;

/// An update run's job number [seq], as a test needs it.
///
/// It writes [mods], by default the base of the folder `mod<seq>`.
/// Its file is listed at [size] bytes.
/// A job past its download carries [archive], by default a file that does not exist.
DownloadJob updateJob(
  int seq, {
  DownloadJobState state = DownloadJobState.queued,
  UpdateStep? step,
  int size = 10,
  List<UpdateMod>? mods,
  UpdateKind kind = UpdateKind.update,
  File? archive,
  bool waited = false,
  bool deferred = false,
  UpdateHalt? halt,
  Object? error,
}) {
  final landed = state != DownloadJobState.queued && state != DownloadJobState.running;
  return DownloadJob(
    seq: seq,
    request: DownloadRequest(url: Uri.parse('https://gamebanana.com/dl/$seq'), expectedSize: size),
    intent: DownloadIntent.update,
    subject: 'mod $seq',
    file: GbFile(idRow: seq, file: 'mod$seq.zip', filesize: size, downloadUrl: 'https://gamebanana.com/dl/$seq'),
    state: state,
    updateStep: step,
    result: landed
        ? DownloadResult(file: archive ?? File('/nonexistent/update$seq.zip'), totalBytes: size)
        : null,
    update: UpdateTask(mods: mods ?? [baseOf('mod$seq', seq)], kind: kind),
    waited: waited,
    deferred: deferred,
    halt: halt,
    error: error,
  );
}

/// The base layer of the folder [modId], whose mod page is [remoteId], picked while its record named [heldFileId],
/// from a check whose Ignore would have dismissed up to [dismissUpTo].
UpdateMod baseOf(String modId, int remoteId, {int? heldFileId, String? name, DateTime? dismissUpTo}) =>
    UpdateMod(modId: modId, layer: DownloadKey.base(remoteId), heldFileId: heldFileId, name: name, dismissUpTo: dismissUpTo);

/// A patch layer of the folder [modId], whose mod page is [remoteId], picked while its record named [heldFileId].
UpdateMod patchOf(String modId, int remoteId, {int? heldFileId}) =>
    UpdateMod(modId: modId, layer: DownloadKey.patch(remoteId), heldFileId: heldFileId);
