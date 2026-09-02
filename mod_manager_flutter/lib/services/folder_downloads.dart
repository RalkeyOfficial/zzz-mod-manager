/// **The flat patch-file list, derived from the stack.**
///
/// This file used to hold the whole compensation layer for a model that stored
/// one download in `origin`'s own fields and the rest in a companion list with
/// roles *relative* to it: an absolute-role enum, a per-entry wrapper, a
/// derivation from two signals, and a partition to put the mod's half first.
/// `ModOrigin.downloads` is ordered bottom-up, so all of that is now the list
/// itself — `origin.base`, `origin.patches`, and the order they are already in.
///
/// What is left is the one thing that genuinely has to be computed: the flat
/// `string[]` an already-released build can still read.
library;

import '../models/mod_origin.dart';

/// **Every file in this folder that belongs to a patch**, in on-disk spelling.
///
/// The union of every layer above the bottom of the stack, in stack order — the
/// order the files themselves go on disk
/// ([`applying-updates.md` §6](../../docs/applying-updates.md)).
///
/// **Kept in step for compatibility rather than tidiness.** The authority is
/// each layer's own `files` list; `ingest.patch_files` exists because
/// `ModIngest` filters that key to plain strings, so an already-released build
/// reading per-download objects would see *no* patch files and flatten the patch
/// away on the next base update.
///
/// Empty for a folder with no per-layer registries — which is every mod
/// installed before they existed. A caller must treat that as "nothing to
/// derive" and leave whatever `patch_files` is already recorded alone, since
/// that hand-written list is the only thing making such a folder rebuildable.
List<String> derivedPatchFiles(ModOrigin origin) => [
      for (final patch in origin.patches)
        for (final file in patch.files) file.path,
    ];
