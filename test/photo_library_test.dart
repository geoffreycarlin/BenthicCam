import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gopro_gps_cam/services/photo_library.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('lib'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('create, select (remembered), move and delete folders', () async {
    final lib = PhotoLibrary(Directory('${tmp.path}/GoProGPS'));
    await lib.load();
    expect(await lib.folders(), ['Photos']);

    expect(await lib.validateNewName(''), isNotNull);
    expect(await lib.validateNewName('a/b'), isNotNull);
    expect(
        await lib.validateNewName('photos'), isNotNull); // clashes with default
    await lib.createFolder('Site visit 1');
    await lib.createFolder('Bridge');
    expect(await lib.validateNewName('bridge'), isNotNull);
    expect(await lib.folders(), ['Photos', 'Bridge', 'Site visit 1']);

    await lib.selectFolder('Site visit 1');
    final photo = File('${lib.currentDir.path}/GOPR0001.jpg')
      ..writeAsBytesSync([1, 2, 3]);
    expect((await lib.photosIn()).length, 1);

    // Remembered across launches.
    final again = PhotoLibrary(lib.root);
    await again.load();
    expect(again.currentFolder, 'Site visit 1');

    // Can't delete a folder with photos; move it out first.
    expect(() => lib.deleteFolder('Site visit 1'), throwsException);
    final moved = await lib.move(photo, 'Bridge');
    expect(moved.path, endsWith('Bridge/GOPR0001.jpg'));
    expect(await lib.countIn('Site visit 1'), 0);

    // Name clash on move gets a suffix.
    File('${lib.currentDir.path}/GOPR0001.jpg').writeAsBytesSync([4]);
    final moved2 =
        await lib.move(File('${lib.currentDir.path}/GOPR0001.jpg'), 'Bridge');
    expect(moved2.path, endsWith('Bridge/GOPR0001_2.jpg'));

    await lib.deleteFolder('Site visit 1');
    expect(lib.currentFolder, 'Photos');
    expect(await lib.folders(), ['Photos', 'Bridge']);
    expect(() => lib.deleteFolder('Photos'), throwsException);
    expect(lib.galleryAlbumFor('Bridge'), 'GoPro GPS - Bridge');
  });
}
