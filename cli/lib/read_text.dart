import 'dart:convert';
import 'dart:io';

/// Reads a vault file as text, keeping going past bytes that are not UTF-8
/// (a note saved by another tool or an old export), so one such file cannot
/// stop a search, a lint or a note read. Bad bytes come back as U+FFFD.
String readText(File f) => utf8.decode(f.readAsBytesSync(), allowMalformed: true);

/// Whether [f] holds anything that is not valid UTF-8.
bool isUtf8(File f) {
  try {
    utf8.decode(f.readAsBytesSync());
    return true;
  } on FormatException {
    return false;
  }
}
