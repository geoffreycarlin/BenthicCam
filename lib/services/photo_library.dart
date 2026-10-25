import 'dart:convert';
import 'dart:io';

/// Photos are kept in folders inside the app's storage:
///
///   Documents/GoProGPS/              <- the "Photos" folder (default)
///   Documents/GoProGPS/Site visit 1/ <- folders you create
///
/// The current folder is remembered between launches.
class PhotoLibrary {
  static const defaultFolder = 'Photos';
  static const _settingsFile = '.settings.json';

  final Directory root;
  String currentFolder = defaultFolder;

  PhotoLibrary(this.root);

  Future<void> load() async {
    if (!await root.exists()) await root.create(recursive: true);
    try {
      final json =
          jsonDecode(await File('${root.path}/$_settingsFile').readAsString());
      final f = json['folder'] as String?;
      if (f != null && (await folders()).contains(f)) currentFolder = f;
    } catch (_) {/* first run */}
  }

  Future<void> _save() async {
    await File('${root.path}/$_settingsFile')
        .writeAsString(jsonEncode({'folder': currentFolder}));
  }

  Directory dirOf(String folder) =>
      folder == defaultFolder ? root : Directory('${root.path}/$folder');

  Directory get currentDir => dirOf(currentFolder);

  /// "Photos" first, then the others alphabetically.
  Future<List<String>> folders() async {
    final names = <String>[];
    if (await root.exists()) {
      await for (final e in root.list()) {
        if (e is Directory) {
          final n = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (!n.startsWith('.')) names.add(n);
        }
      }
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [defaultFolder, ...names];
  }

  /// Returns an error message, or null if [name] is a valid new folder name.
  Future<String?> validateNewName(String name) async {
    final n = name.trim();
    if (n.isEmpty) return 'Enter a name';
    if (n.length > 60) return 'Name is too long';
    if (n.startsWith('.')) return 'Name cannot start with a dot';
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(n)) {
      return r'Name cannot contain \ / : * ? " < > |';
    }
    final existing = (await folders()).map((f) => f.toLowerCase());
    if (existing.contains(n.toLowerCase())) {
      return 'A folder with that name already exists';
    }
    return null;
  }

  Future<void> createFolder(String name) async {
    final err = await validateNewName(name);
    if (err != null) throw Exception(err);
    await dirOf(name.trim()).create(recursive: true);
  }

  Future<void> selectFolder(String name) async {
    currentFolder = name;
    if (!await currentDir.exists()) await currentDir.create(recursive: true);
    await _save();
  }

  /// JPEGs in [folder] (default: current), newest first.
  Future<List<File>> photosIn([String? folder]) async {
    final dir = dirOf(folder ?? currentFolder);
    if (!await dir.exists()) return [];
    final files = <File>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.jpg')) files.add(e);
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  Future<int> countIn(String folder) async => (await photosIn(folder)).length;

  /// Moves [file] into [folder]; returns the moved file.
  Future<File> move(File file, String folder) async {
    final dest = dirOf(folder);
    if (!await dest.exists()) await dest.create(recursive: true);
    final name = file.uri.pathSegments.last;
    var target = File('${dest.path}/$name');
    var i = 2;
    while (await target.exists()) {
      final dot = name.lastIndexOf('.');
      target = File(
          '${dest.path}/${name.substring(0, dot)}_$i${name.substring(dot)}');
      i++;
    }
    return file.rename(target.path);
  }

  /// Deletes an empty folder (never the default one).
  Future<void> deleteFolder(String folder) async {
    if (folder == defaultFolder) {
      throw Exception('The Photos folder cannot be deleted');
    }
    if (await countIn(folder) > 0) {
      throw Exception('Move or delete the photos in it first');
    }
    await dirOf(folder).delete(recursive: true);
    if (currentFolder == folder) await selectFolder(defaultFolder);
  }

  /// Album name used when also saving to the phone gallery.
  String galleryAlbumFor(String folder) =>
      folder == defaultFolder ? 'GoPro GPS' : 'GoPro GPS - $folder';
}
