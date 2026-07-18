import 'dart:typed_data';

/// A staged gallery entry in the edit dialog. It's one of: an image already in
/// the mod folder ([existingPath]), a newly picked file to import on save
/// ([pickedPath]), or pasted bytes to write on save ([pastedBytes]). Nothing
/// touches disk until the dialog is saved.
class EditImage {
  final String? existingPath;
  final String? pickedPath;
  final Uint8List? pastedBytes;

  const EditImage.existing(this.existingPath)
    : pickedPath = null,
      pastedBytes = null;
  const EditImage.picked(this.pickedPath)
    : existingPath = null,
      pastedBytes = null;
  const EditImage.pasted(this.pastedBytes)
    : existingPath = null,
      pickedPath = null;
}
