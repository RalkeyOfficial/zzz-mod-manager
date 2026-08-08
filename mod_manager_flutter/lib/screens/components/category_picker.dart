import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/categories.dart';
import '../../utils/zzz_characters.dart';

/// Opens the category/character picker.
///
/// Returns the chosen id (a character id or a built-in category id), or `null`
/// if the picker was dismissed without choosing (caller keeps the current
/// value). A category is required, so there is no "clear" option.
Future<String?> showCategoryPicker(
  BuildContext context, {
  required String currentId,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _CategoryPickerDialog(currentId: currentId),
  );
}

class _CategoryPickerDialog extends StatefulWidget {
  const _CategoryPickerDialog({required this.currentId});

  final String currentId;

  @override
  State<_CategoryPickerDialog> createState() => _CategoryPickerDialogState();
}

class _CategoryPickerDialogState extends State<_CategoryPickerDialog> {
  static const Color _accent = Color(AppConstants.primaryColor);
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  AppLocalizations get loc => context.loc;

  bool _matches(String haystack) =>
      _query.isEmpty || haystack.toLowerCase().contains(_query);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = (media.size.width * 0.85).clamp(420.0, 720.0);
    final height = (media.size.height * 0.7).clamp(320.0, 620.0);

    final categories = [
      for (final cat in builtInCategories)
        if (_matches(loc.t(cat.labelKey))) cat,
    ];
    final characterIds = [
      for (final id in zzzCharacterIds)
        if (_matches(
          '${getCharacterDisplayName(id)} ${getCharacterRealName(id) ?? ''} $id',
        ))
          id,
    ];
    final empty = categories.isEmpty && characterIds.isEmpty;

    return AlertDialog(
      title: Text(loc.t('mods.dialog.select_category')),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              decoration: InputDecoration(
                isDense: true,
                hintText: loc.t('mods.dialog.search_category'),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: empty
                  ? Center(
                      child: Text(
                        loc.t('mods.toolbar.no_results'),
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    )
                  : ListView(
                      children: [
                        if (categories.isNotEmpty) ...[
                          _sectionHeader(
                            loc.t('categories.section_categories'),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final cat in categories) _categoryChip(cat),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (characterIds.isNotEmpty) ...[
                          _sectionHeader(
                            loc.t('categories.section_characters'),
                          ),
                          GridView.builder(
                            shrinkWrap: true,
                            primary: false,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 92,
                                  mainAxisExtent: 100,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                ),
                            itemCount: characterIds.length,
                            itemBuilder: (_, i) =>
                                _characterTile(characterIds[i]),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(loc.t('mods.dialog.cancel')),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Colors.grey[600],
        letterSpacing: 0.3,
      ),
    ),
  );

  Widget _categoryChip(CategoryData cat) {
    final selected = cat.id == widget.currentId;
    return Material(
      color: selected ? _accent.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.pop(context, cat.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? _accent : Colors.grey.withValues(alpha: 0.4),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(cat.icon, size: 18, color: Colors.grey[700]),
              const SizedBox(width: 8),
              Text(loc.t(cat.labelKey), style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _characterTile(String id) {
    final selected = id == widget.currentId;
    final realName = getCharacterRealName(id);
    return Tooltip(
      message: realName != null && realName != getCharacterDisplayName(id)
          ? realName
          : getCharacterDisplayName(id),
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.pop(context, id),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? _accent : Colors.grey.withValues(alpha: 0.35),
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: ClipOval(
                child: Image.asset(
                  'assets/characters/${getCharacterAssetName(id)}.png',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    color: Colors.grey.withValues(alpha: 0.15),
                    child: Icon(
                      Icons.person,
                      size: 28,
                      color: Colors.grey[600],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Text(
                getCharacterDisplayName(id),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? _accent : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
