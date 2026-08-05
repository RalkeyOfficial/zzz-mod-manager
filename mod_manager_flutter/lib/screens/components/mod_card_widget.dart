import 'dart:io';
import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../models/character_info.dart';

class ModCardWidget extends StatefulWidget {
  final ModInfo mod;
  final bool isDarkMode;
  final VoidCallback onFavoriteToggle;
  final VoidCallback onShowDetails;
  final VoidCallback onOpenLink;

  const ModCardWidget({
    Key? key,
    required this.mod,
    required this.isDarkMode,
    required this.onFavoriteToggle,
    required this.onShowDetails,
    required this.onOpenLink,
  }) : super(key: key);

  @override
  State<ModCardWidget> createState() => _ModCardWidgetState();
}

class _ModCardWidgetState extends State<ModCardWidget> {
  static const Color _accent = Color(0xFF0EA5E9);

  bool isHovered = false;

  bool get _hasImage =>
      widget.mod.imagePath != null && File(widget.mod.imagePath!).existsSync();

  @override
  Widget build(BuildContext context) {
    final mod = widget.mod;
    return MouseRegion(
      onEnter: (_) => setState(() => isHovered = true),
      onExit: (_) => setState(() => isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        // Scale from the card's centre and lift slightly straight up, rather
        // than growing from the top-left corner toward the top-right.
        transformAlignment: Alignment.center,
        transform: Matrix4.identity()
          ..translate(0.0, isHovered ? -6.0 : 0.0)
          ..scale(isHovered ? 1.03 : 1.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: _getModCardGradient(mod, widget.isDarkMode, isHovered),
          border: Border.all(
            color: _getModCardBorderColor(mod, widget.isDarkMode, isHovered),
            width: mod.isActive ? 2.5 : (isHovered ? 2.0 : 1.2),
          ),
          boxShadow: _getModCardShadows(mod, widget.isDarkMode, isHovered),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _buildImage(mod)),
            _buildFooter(mod),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(ModInfo mod) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      child: Container(
        decoration: BoxDecoration(
          gradient: _hasImage
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    widget.isDarkMode
                        ? const Color(0xFF374151)
                        : const Color(0xFFF3F4F6),
                    widget.isDarkMode
                        ? const Color(0xFF1F2937)
                        : const Color(0xFFE5E7EB),
                  ],
                ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_hasImage)
              Image.file(
                File(mod.imagePath!),
                fit: BoxFit.cover,
                // Decode to the card's size rather than the file's. Without this a
                // 2560px screenshot is held as 14 MB of pixels to fill a 320px
                // card, and a handful of them evict the whole shared ImageCache —
                // including the marketplace's previews. See
                // AppConstants.modCardDecodeWidth for the measurements.
                cacheWidth: AppConstants.modCardDecodeWidth,
                key: ValueKey('${mod.id}_${mod.imagePath}'),
              )
            else
              Center(
                child: Icon(
                  Icons.image_outlined,
                  size: 40,
                  color: widget.isDarkMode
                      ? const Color.fromRGBO(255, 255, 255, 0.4)
                      : const Color.fromRGBO(0, 0, 0, 0.4),
                ),
              ),

            // Bottom scrim so overlay badges stay legible over any image.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Color.fromRGBO(0, 0, 0, 0.45),
                  ],
                  stops: [0.55, 1.0],
                ),
              ),
            ),

            // Top-left: open the read-only details dialog.
            Positioned(
              top: 8,
              left: 8,
              child: _circleButton(Icons.info_outline, widget.onShowDetails),
            ),

            // Top-right: enabled state.
            Positioned(top: 10, right: 10, child: _statusBadge(mod)),

            // Bottom-right: actions — open source link (if any) + favorite.
            Positioned(
              bottom: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mod.sourceUrl != null && mod.sourceUrl!.isNotEmpty) ...[
                    _circleButton(Icons.open_in_new, widget.onOpenLink),
                    const SizedBox(width: 6),
                  ],
                  _favoriteButton(mod),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Enabled/disabled shown as a toggle switch — green with the knob to the
  /// right when active, grey with the knob to the left when inactive. Reads as
  /// on/off (not "delete"). Clicking it toggles via the card body.
  Widget _statusBadge(ModInfo mod) {
    final active = mod.isActive;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 42,
      height: 22,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFF10B981)
            : Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(11),
        boxShadow: [
          BoxShadow(
            color: active
                ? const Color.fromRGBO(16, 185, 129, 0.4)
                : const Color.fromRGBO(0, 0, 0, 0.3),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: active ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 18,
          height: 18,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: Icon(
            active ? Icons.check_rounded : Icons.power_settings_new_rounded,
            size: 12,
            color: active
                ? const Color(0xFF10B981)
                : Colors.black.withOpacity(0.45),
          ),
        ),
      ),
    );
  }

  /// A translucent circular icon button. Its own InkWell wins the gesture, so
  /// tapping it doesn't also trigger the card-body toggle.
  Widget _circleButton(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.black.withOpacity(0.35),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: Colors.white.withOpacity(0.85)),
        ),
      ),
    );
  }

  Widget _favoriteButton(ModInfo mod) {
    return Material(
      color: Colors.black.withOpacity(0.35),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: widget.onFavoriteToggle,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            mod.isFavorite ? Icons.star : Icons.star_border,
            size: 18,
            color: mod.isFavorite
                ? const Color(0xFFFACC15)
                : Colors.white.withOpacity(0.85),
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(ModInfo mod) {
    final hasTags = mod.tags.isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
        color: mod.isActive
            ? (widget.isDarkMode
                ? const Color.fromRGBO(14, 165, 233, 0.1)
                : const Color.fromRGBO(14, 165, 233, 0.05))
            : (widget.isDarkMode
                ? const Color.fromRGBO(255, 255, 255, 0.02)
                : const Color.fromRGBO(0, 0, 0, 0.01)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            mod.name,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: mod.isActive
                  ? _accent
                  : (widget.isDarkMode
                      ? const Color.fromRGBO(255, 255, 255, 0.9)
                      : const Color.fromRGBO(0, 0, 0, 0.8)),
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (hasTags) ...[
            const SizedBox(height: 8),
            _tagStrip(mod.tags),
          ],
        ],
      ),
    );
  }

  /// A compact one-line-ish strip of tags: shows the first few and a "+N"
  /// overflow chip so the footer height stays predictable.
  Widget _tagStrip(List<String> tags) {
    const maxShown = 3;
    final shown = tags.take(maxShown).toList();
    final extra = tags.length - shown.length;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      clipBehavior: Clip.hardEdge,
      children: [
        for (final t in shown) _tagChip(t),
        if (extra > 0) _tagChip('+$extra', muted: true),
      ],
    );
  }

  Widget _tagChip(String label, {bool muted = false}) {
    final base = muted
        ? (widget.isDarkMode ? Colors.white54 : Colors.black45)
        : _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: base.withOpacity(0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: base.withOpacity(0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: widget.isDarkMode
              ? Colors.white.withOpacity(0.85)
              : Colors.black.withOpacity(0.7),
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  // Допоміжні методи для стилізації
  LinearGradient _getModCardGradient(ModInfo mod, bool isDarkMode, bool isHovered) {
    if (mod.isActive) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.fromRGBO(14, 165, 233, isHovered ? 0.2 : 0.15),
          Color.fromRGBO(59, 130, 246, isHovered ? 0.15 : 0.1),
          Color.fromRGBO(139, 92, 246, isHovered ? 0.1 : 0.05),
        ],
      );
    }

    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        isDarkMode
            ? Color.fromRGBO(31, 41, 55, isHovered ? 0.9 : 0.8)
            : Color.fromRGBO(255, 255, 255, isHovered ? 0.95 : 0.9),
        isDarkMode
            ? Color.fromRGBO(17, 24, 39, isHovered ? 0.95 : 0.9)
            : Color.fromRGBO(249, 250, 251, isHovered ? 0.98 : 0.95),
      ],
    );
  }

  Color _getModCardBorderColor(ModInfo mod, bool isDarkMode, bool isHovered) {
    if (mod.isActive) {
      return Color.fromRGBO(14, 165, 233, isHovered ? 0.8 : 0.6);
    }

    if (isHovered) {
      return isDarkMode
          ? const Color.fromRGBO(255, 255, 255, 0.2)
          : const Color.fromRGBO(0, 0, 0, 0.15);
    }

    return isDarkMode
        ? const Color.fromRGBO(255, 255, 255, 0.08)
        : const Color.fromRGBO(0, 0, 0, 0.06);
  }

  List<BoxShadow> _getModCardShadows(ModInfo mod, bool isDarkMode, bool isHovered) {
    List<BoxShadow> shadows = [];

    if (mod.isActive) {
      shadows.addAll([
        BoxShadow(
          color: Color.fromRGBO(14, 165, 233, isHovered ? 0.3 : 0.2),
          blurRadius: isHovered ? 20 : 15,
          offset: Offset(0, isHovered ? 8 : 6),
          spreadRadius: isHovered ? 2 : 1,
        ),
        BoxShadow(
          color: Color.fromRGBO(14, 165, 233, isHovered ? 0.15 : 0.1),
          blurRadius: isHovered ? 30 : 25,
          offset: Offset(0, isHovered ? 12 : 10),
          spreadRadius: isHovered ? 3 : 2,
        ),
      ]);
    } else {
      shadows.add(
        BoxShadow(
          color: isDarkMode
              ? Color.fromRGBO(0, 0, 0, isHovered ? 0.4 : 0.2)
              : Color.fromRGBO(156, 163, 175, isHovered ? 0.2 : 0.1),
          blurRadius: isHovered ? 15 : 10,
          offset: Offset(0, isHovered ? 6 : 4),
          spreadRadius: isHovered ? 1 : 0,
        ),
      );
    }

    if (isHovered && !mod.isActive) {
      shadows.add(
        const BoxShadow(
          color: Color.fromRGBO(255, 255, 255, 0.05),
          blurRadius: 20,
          offset: Offset(0, 8),
          spreadRadius: 1,
        ),
      );
    }

    return shadows;
  }
}
