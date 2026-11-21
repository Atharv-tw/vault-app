import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dates.dart';
import 'store.dart';

/// A short fingerprint of a note's text, only used to notice that it changed.
String noteHash(String text) {
  // FNV-1a, 64-bit.
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(text)) {
    h ^= b;
    h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// Whether a vault-relative path is a note that syncs: Markdown, not in `raw/`
/// (the diary word for word stays on this device), not hidden (`.git`,
/// `.obsidian`, `.conflicts`).
bool isSyncedNotePath(String rel) {
  final parts = rel.split('/');
  if (!rel.toLowerCase().endsWith('.md')) return false;
  if (parts.first.toLowerCase() == 'raw') return false;
  return !parts.any((s) => s.startsWith('.'));
}

class MirrorResult {
  int imported = 0;
  int exported = 0;
  int deleted = 0;

  /// Notes changed in both places since the last pass: the newer one won, the
  /// other is kept under `.conflicts/` in the vault.
  final conflicts = <String>[];

  int get changes => imported + exported + deleted + conflicts.length;

  Map<String, Object?> toJson() => {
        'imported': imported,
        'exported': exported,
        'deleted': deleted,
        if (conflicts.isNotEmpty) 'conflicts': conflicts,
      };
}

/// Keeps the vault folder and the synced `notes` table in step, both ways.
///
/// A note edited in the folder (by hand, in Obsidian, by an agent) goes into
/// the table; a note that arrived through sync (written on another device) is
/// written to the folder. Deletions travel both ways. `notes_mirror` holds what
/// the folder had at the last pass, which tells a local edit from a remote one;
/// when both changed, the newer one wins and the other is saved, not lost.
class NotesMirror {
  NotesMirror(this.store, this.root);

  final Store store;
  final String root;

  /// Vault-relative paths (with `/`) of every note in the folder.
  List<String> files() {
    final dir = Directory(root);
    if (!dir.existsSync()) return [];
    final out = <String>[];
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: root).split(p.separator).join('/');
      if (isSyncedNotePath(rel)) out.add(rel);
    }
    out.sort();
    return out;
  }

  MirrorResult sync({DateTime? now}) {
    final r = MirrorResult();
    final db = store.db;
    _dedupe();
    final mirror = {
      for (final row in db.select('SELECT path, hash FROM notes_mirror')) row['path'] as String: row['hash'] as String,
    };
    final live = {for (final n in store.notes()) n['path'] as String: n};
    // First pass on this device (say a fresh clone): where folder and store differ, the store's copy is the shared
    // one, so it wins and the folder's version is kept aside; a fresh clone's newer file times mean nothing.
    final firstPass = mirror.isEmpty && live.isNotEmpty;
    final paths = {...files(), ...live.keys, ...mirror.keys}.where(isSyncedNotePath).toList()..sort();

    void remember(String path, String? hash) {
      if (hash == null) {
        db.execute('DELETE FROM notes_mirror WHERE path = ?', [path]);
      } else {
        db.execute('INSERT OR REPLACE INTO notes_mirror (path, hash) VALUES (?, ?)', [path, hash]);
      }
    }

    db.execute('BEGIN');
    try {
      for (final path in paths) {
        final file = File(p.joinAll([root, ...path.split('/')]));
        final hasFile = file.existsSync();
        final text = hasFile ? _read(file) : null;
        final fh = text == null ? null : noteHash(text);
        final row = live[path];
        final body = row?['body'] as String?;
        final rh = body == null ? null : noteHash(body);
        final m = mirror[path];

        if (hasFile && row != null) {
          if (fh == rh) {
            if (m != fh) remember(path, fh);
          } else if (m == rh) {
            store.setNoteBody(row['id'] as String, text!);
            r.imported++;
            remember(path, fh);
          } else if (m == fh) {
            _write(file, body!);
            r.exported++;
            remember(path, rh);
          } else {
            // Both sides changed since the last pass (or this is the first pass).
            final fileTime = utcStamp(file.lastModifiedSync());
            final fileNewer = !firstPass && fileTime.compareTo(row['updated_at'] as String) > 0;
            _keepConflict(path, fileNewer ? body! : text!, now ?? DateTime.now());
            if (fileNewer) {
              store.setNoteBody(row['id'] as String, text!);
              remember(path, fh);
            } else {
              _write(file, body!);
              remember(path, rh);
            }
            r.conflicts.add(path);
          }
        } else if (hasFile) {
          final gone = db.select('SELECT 1 FROM notes WHERE path = ? AND deleted_at IS NOT NULL LIMIT 1', [path]).isNotEmpty;
          if (gone && m == fh) {
            file.deleteSync();
            r.deleted++;
            remember(path, null);
          } else {
            store.addNote(path, text!);
            r.imported++;
            remember(path, fh);
          }
        } else if (row != null) {
          if (m != null && m == rh) {
            store.deleteNote(row['id'] as String);
            r.deleted++;
            remember(path, null);
          } else {
            _write(file, body!);
            r.exported++;
            remember(path, rh);
          }
        } else {
          remember(path, null);
        }
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return r;
  }

  /// Two devices may each create the same path before they sync: keep the newer.
  void _dedupe() {
    final dups = store.db.select(
      'SELECT path FROM notes WHERE deleted_at IS NULL GROUP BY path HAVING COUNT(*) > 1');
    for (final d in dups) {
      final rows = store.db.select(
        'SELECT id FROM notes WHERE path = ? AND deleted_at IS NULL ORDER BY updated_at DESC, id', [d['path']]);
      for (final old in rows.skip(1)) {
        store.deleteNote(old['id'] as String);
      }
    }
  }

  String _read(File f) => utf8.decode(f.readAsBytesSync(), allowMalformed: true);

  void _write(File f, String text) {
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  void _keepConflict(String path, String losing, DateTime now) {
    final stamp = utcStamp(now).replaceAll(':', '').replaceAll('-', '').split('.').first;
    final f = File(p.joinAll([root, '.conflicts', ...p.withoutExtension(path).split('/')]) + ' $stamp.md');
    _write(f, losing);
  }
}
