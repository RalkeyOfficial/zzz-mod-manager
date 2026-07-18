1. ✅ DONE — soldier 0 anby needs to have another alias called "sanby" so that it auto detects soldier 0 anby correctly (the community tends to call her sanby). AnbyS is also a alias that is used, though not as much.
2. renaming a mod takes way to long for what should be a simple folder rename, if you open the edit modal during the time its renaming it, and save the edits after its finished, it'll create a empty folder with its old name and only the metadata in it. Improving the rename performance should fix this.
3. (related to #2) performance of renaming and other editorial actions is still slow when a lot of mods exist. Research on cause of performance decrease needs to be done, should be seperate of the other todo's to dedicate time to it.
4. ✅ DONE — We need a action to open a mod in file-explorer.
5. ✅ DONE — We also need a action to delete a mod, with a warning & confirmation modal.
6. Installing a zip with 2 folders in it (e.g. `{mod name}` and `previews`) will install both folders as 2 seperate mods. Perhaps we need to update the install modal so you can select what folders to install (when this situation applies)
7. ✅ DONE — I want to be able to edit the description inline in the detail modal.
8. ✅ DONE — the markdown `> [!INFO]` does nothing compared to `> [!WARNING]`.
9. ✅ DONE — cleanup: split up files into components, services, etc. `mods_screen.dart` split into components/dialogs/utils (4578 → ~1760 lines, 14 new files, no behaviour change). — IN PROGRESS: `mods_screen.dart` split into components/dialogs/utils (4578 → ~1760 lines, 14 new files, no behaviour change). Remaining large files to split: `settings_screen.dart` (~1200), `marketplace_screen.dart` (~1150).
