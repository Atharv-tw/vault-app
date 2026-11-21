import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:vault_cli/vault.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  test('notes sync puts the folder into the synced store, and needs no sign-in to do it', () async {
    final tmp = Directory.systemTemp.createTempSync('notes_sync');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final vault = p.join(tmp.path, 'vault');
    File(p.join(vault, 'Me.md')).createSync(recursive: true);
    File(p.join(vault, 'Me.md')).writeAsStringSync('# Me\n');
    File(p.join(vault, 'raw', '2026-11-20.md')).createSync(recursive: true);
    final store = Store(openMemoryDb());

    final r = await syncNotes(store, vault);
    expect((r['from_folder'] as Map)['imported'], 1);
    expect(r['signed_in'], isFalse);
    expect(syncNotesLine(r), contains('Not signed in'));
    expect(store.notes().single['path'], 'Me.md');
    expect(store.db.select('SELECT dirty FROM notes').single['dirty'], 1); // waits to be pushed

    final again = await syncNotes(store, vault);
    expect(syncNotesLine(again), startsWith('Notes are in step.'));
  });
}
