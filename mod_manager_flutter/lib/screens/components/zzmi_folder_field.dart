import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/app_localizations.dart';
import '../../services/shader_fixes/zzmi_layout.dart';

/// Builds the label, text field and Browse button in the host screen's style.
/// [status] goes under the field, inside whatever frame the screen draws.
typedef ZzmiFieldBuilder = Widget Function(VoidCallback onBrowse, Widget status);

/// The ZZMI folder setting, shared by settings and first-run setup.
///
/// Browse resolves the pick to the folder holding `d3dx.ini`, and a status line
/// says where links and shader fixes go, or warns when there is no `d3dx.ini`.
/// The warning does not block saving: mods without shader files work without it,
/// and enabling a shader mod refuses on its own (`docs/configuration.md` §2).
class ZzmiFolderField extends StatefulWidget {
  const ZzmiFolderField({
    super.key,
    required this.controller,
    required this.builder,
    this.storedZzmiPath,
    this.storedLinksFolder,
  });

  final TextEditingController controller;
  final ZzmiFieldBuilder builder;

  /// The saved ZZMI folder and the links folder the config worked out from it.
  /// While the field still holds [storedZzmiPath], the status line shows
  /// [storedLinksFolder], the folder links really go into.
  final String? storedZzmiPath;
  final String? storedLinksFolder;

  @override
  State<ZzmiFolderField> createState() => _ZzmiFolderFieldState();
}

class _ZzmiFolderFieldState extends State<ZzmiFolderField> {
  static const _debounce = Duration(milliseconds: 300);

  Timer? _timer;
  int _generation = 0;
  String _checked = '';
  _Status? _status;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    // The listener also fires on selection changes, which need no new check.
    if (widget.controller.text == _checked) return;
    _timer?.cancel();
    _timer = Timer(_debounce, _refresh);
  }

  Future<void> _refresh() async {
    _timer?.cancel();
    final text = widget.controller.text.trim();
    _checked = widget.controller.text;
    final generation = ++_generation;
    final status = text.isEmpty ? null : await _statusFor(text);
    if (!mounted || generation != _generation) return;
    setState(() => _status = status);
  }

  Future<_Status> _statusFor(String folder) async {
    final hasIni = await File(p.join(folder, 'd3dx.ini')).exists();
    final shaders = hasIni ? await shaderFolderIn(folder) : null;
    if (shaders == null) return const _Status.missing();
    final stored = widget.storedZzmiPath;
    final links = stored != null &&
            widget.storedLinksFolder != null &&
            p.equals(stored, folder)
        ? widget.storedLinksFolder!
        : linksFolderIn(folder);
    return _Status.found(links: links, shaders: shaders);
  }

  Future<void> _browse() async {
    final picked = await FilePicker.platform.getDirectoryPath();
    if (picked == null || !mounted) return;
    final resolved = await resolveZzmiFolder(picked) ?? picked;
    if (!mounted) return;
    widget.controller.text = resolved;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(_browse, _StatusLine(status: _status));
}

class _Status {
  const _Status.found({required String this.links, required String this.shaders});
  const _Status.missing()
      : links = null,
        shaders = null;

  final String? links;
  final String? shaders;

  bool get found => links != null;
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});

  final _Status? status;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    if (status == null) return const SizedBox.shrink();
    final loc = context.loc;
    final theme = Theme.of(context);
    final color = status.found ? Colors.grey[600] : theme.colorScheme.error;
    final text = status.found
        ? loc.t('settings.paths.zzmi_status_found', params: {
            'links': status.links!,
            'shaders': status.shaders!,
          })
        : loc.t('settings.paths.zzmi_status_missing');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            status.found ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
