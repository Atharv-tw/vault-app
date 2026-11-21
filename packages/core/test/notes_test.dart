import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

import 'sync_test.dart' show FakeRemote;

/// A device: its own database and its own vault folder.
class Device {
  Device(String name, Directory tmp)
      : store = Store(openMemoryDb()),
        root = p.join(tmp.path, name) {
    Directory(root).createSync(recursive: true);
  }
  final Store store;
  final String root;
  NotesMirror get mirror => NotesMirror(store, root);
  File file(String rel) => File(p.join(root, rel));
  void write(String rel, String text) => (file(rel)..parent.createSync(recursive: true)).writeAsStringSync(text);
  String read(String rel) => file(rel).readAsStringSync();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('notes_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('import skips raw/ and hidden folders; a second pass changes nothing', () {
    final d = Device('laptop', tmp);
    d.write('Me.md', '# Me\n');
    d.write('projects/Helios/log.md', '- 2026-11-01: started\n');
    d.write('raw/2026-11-20.md', 'my diary, word for word');
    d.write('.obsidian/workspace.md', 'ui');
    d.write('notes/plan.txt', 'not markdown');
    final r = d.mirror.sync();
    expect(r.imported, 2);
    expect(d.store.notes().map((n) => n['path']), ['Me.md', 'projects/Helios/log.md']);
    expect(d.mirror.sync().changes, 0);
  });

  test('a note edited on one device reaches the other device\'s folder, both ways', () async {
    final remote = FakeRemote();
    final laptop = Device('laptop', tmp), phone = Device('vm', tmp);
    laptop.write('Rules.md', '# Rules\n- one\n');
    laptop.mirror.sync();
    await SyncEngine(laptop.store, remote).sync();
    await SyncEngine(phone.store, remote).sync();
    expect(phone.mirror.sync().exported, 1);
    expect(phone.read('Rules.md'), '# Rules\n- one\n');

    // edited on the second device (an agent there), back to the laptop
    phone.write('Rules.md', '# Rules\n- one\n- two\n');
    expect(phone.mirror.sync().imported, 1);
    await SyncEngine(phone.store, remote).sync();
    await SyncEngine(laptop.store, remote).sync();
    expect(laptop.mirror.sync().exported, 1);
    expect(laptop.read('Rules.md'), contains('- two'));
  });

  test('deleting a note in the folder deletes it everywhere', () async {
    final remote = FakeRemote();
    final a = Device('a', tmp), b = Device('b', tmp);
    a.write('notes/Old idea.md', 'x');
    a.mirror.sync();
    await SyncEngine(a.store, remote).sync();
    await SyncEngine(b.store, remote).sync();
    b.mirror.sync();
    expect(b.file('notes/Old idea.md').existsSync(), isTrue);

    a.file('notes/Old idea.md').deleteSync();
    expect(a.mirror.sync().deleted, 1);
    await SyncEngine(a.store, remote).sync();
    await SyncEngine(b.store, remote).sync();
    expect(b.mirror.sync().deleted, 1);
    expect(b.file('notes/Old idea.md').existsSync(), isFalse);
  });

  test('changed in both places: the newer wins and the other is kept under .conflicts', () async {
    final d = Device('laptop', tmp);
    d.write('Ideas.md', 'v1');
    d.mirror.sync();
    final id = d.store.note('Ideas.md')!['id'] as String;
    d.store.setNoteBody(id, 'from the phone'); // arrived through sync
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    d.write('Ideas.md', 'edited in Obsidian'); // newer
    final r = d.mirror.sync();
    expect(r.conflicts, ['Ideas.md']);
    expect(d.store.note('Ideas.md')!['body'], 'edited in Obsidian');
    final kept = Directory(p.join(d.root, '.conflicts')).listSync(recursive: true).whereType<File>().single;
    expect(kept.readAsStringSync(), 'from the phone');
    expect(d.mirror.sync().changes, 0);
  });

  test('the same new path from two devices ends as one note', () async {
    final remote = FakeRemote();
    final a = Device('a', tmp), b = Device('b', tmp);
    a.write('notes/Trip.md', 'from a');
    a.mirror.sync();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    b.write('notes/Trip.md', 'from b');
    b.mirror.sync();
    await SyncEngine(a.store, remote).sync();
    await SyncEngine(b.store, remote).sync();
    b.mirror.sync();
    expect(b.store.notes().where((n) => n['path'] == 'notes/Trip.md').length, 1);
  });

  test('a fresh clone with older text does not overwrite notes changed elsewhere', () async {
    final remote = FakeRemote();
    final laptop = Device('laptop', tmp);
    laptop.write('Me.md', 'v1');
    laptop.mirror.sync();
    final id = laptop.store.note('Me.md')!['id'] as String;
    laptop.store.setNoteBody(id, 'v2 from the phone'); // the shared copy moved on
    await SyncEngine(laptop.store, remote).sync();

    final cloud = Device('cloud', tmp); // tonight's fresh clone still has v1, with a new file time
    cloud.write('Me.md', 'v1');
    await SyncEngine(cloud.store, remote).sync(); // pull first, as syncNotes does
    final r = cloud.mirror.sync();
    expect(cloud.read('Me.md'), 'v2 from the phone');
    expect(r.conflicts, ['Me.md']);
    expect(cloud.store.note('Me.md')!['body'], 'v2 from the phone');
  });

  test('noteHash is stable and sensitive', () {
    expect(noteHash('abc'), noteHash('abc'));
    expect(noteHash('abc'), isNot(noteHash('abd')));
    expect(isSyncedNotePath('raw/x.md'), isFalse);
    expect(isSyncedNotePath('Raw/x.md'), isFalse);
    expect(isSyncedNotePath('days/2026-11-20.md'), isTrue);
  });
}
