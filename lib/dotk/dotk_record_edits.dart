import 'dart:convert';
import 'dart:typed_data';

import 'dotk_records.dart';

/// Edits one entry of a record blob and keeps the bytes of every other entry.
/// Only the map head is rebuilt, with the new count.
abstract class DotkRecordEdits {
  static const primaryKey = 'primary';

  static final _primaryEntry = Uint8List.fromList([
    ..._textHead(primaryKey.length),
    ...ascii.encode(primaryKey),
    0xf5, // true
  ]);

  /// The blob without the entry for [key]. A blob without it comes back as
  /// it is.
  static Uint8List remove(Uint8List blob, String key) {
    final entries = _entries(blob);
    final kept = entries.where((entry) => entry.key != key).toList();
    if (kept.length == entries.length) {
      return blob;
    }
    return _join(blob, kept);
  }

  static Uint8List withoutPrimary(Uint8List blob) => remove(blob, primaryKey);

  /// The blob with `primary: true`. A missing entry goes where deterministic
  /// CBOR orders it, and a `primary` entry with another value is replaced.
  static Uint8List withPrimary(Uint8List blob) {
    final entries = _entries(blob);
    final at = entries.indexWhere((entry) => entry.key == primaryKey);
    if (at >= 0) {
      if (entries[at].value == true) {
        return blob;
      }
      entries[at] = _Entry(primaryKey, true, _primaryEntry);
      return _join(blob, entries);
    }

    final encodedKey = Uint8List.sublistView(
      _primaryEntry,
      0,
      _primaryEntry.length - 1,
    );
    var insertAt = entries.indexWhere(
      (entry) => _byteOrder(entry.encodedKey, encodedKey) > 0,
    );
    if (insertAt < 0) {
      insertAt = entries.length;
    }
    entries.insert(insertAt, _Entry(primaryKey, true, _primaryEntry));
    return _join(blob, entries);
  }

  static int count(Uint8List blob) => DotkRecords.decode(blob).length;

  static List<_Entry> _entries(Uint8List blob) {
    // The decoder validates the whole blob, and keeps the blob's order
    final records = DotkRecords.decode(blob);
    var at = _headLength(blob[0]);
    final entries = <_Entry>[];
    for (final MapEntry(:key, :value) in records.entries) {
      final start = at;
      at += _headLength(blob[at]) + _argument(blob, at);
      final keyEnd = at;
      final next = blob[at];
      if (next == 0xf4 || next == 0xf5) {
        at += 1;
      } else if (next >> 5 == 3) {
        at += _headLength(next) + _argument(blob, at);
      } else {
        at += (value as Uint8List).length;
      }
      entries.add(
        _Entry(
          key,
          value,
          Uint8List.sublistView(blob, start, at),
          keyEnd - start,
        ),
      );
    }
    return entries;
  }

  static Uint8List _join(Uint8List blob, List<_Entry> entries) {
    final builder = BytesBuilder(copy: false)..add(_mapHead(entries.length));
    for (final entry in entries) {
      builder.add(entry.bytes);
    }
    final out = builder.toBytes();
    if (out.length > DotkRecords.blobMaxLength) {
      throw const FormatException('Record blob is over the size cap');
    }
    return out;
  }

  static int _headLength(int head) => switch (head & 0x1f) {
    < 24 => 1,
    24 => 2,
    25 => 3,
    26 => 5,
    _ => throw FormatException('Unsupported CBOR head $head'),
  };

  static int _argument(Uint8List blob, int at) {
    final info = blob[at] & 0x1f;
    if (info < 24) {
      return info;
    }
    return blob
        .sublist(at + 1, at + _headLength(blob[at]))
        .fold(0, (value, byte) => value << 8 | byte);
  }

  static Uint8List _head(int major, int n) => Uint8List.fromList(switch (n) {
    <= 23 => [major << 5 | n],
    <= 0xff => [major << 5 | 24, n],
    <= 0xffff => [major << 5 | 25, n >> 8, n & 0xff],
    _ => [major << 5 | 26, n >> 24, n >> 16 & 0xff, n >> 8 & 0xff, n & 0xff],
  });

  static Uint8List _mapHead(int count) => _head(5, count);

  static Uint8List _textHead(int length) => _head(3, length);

  /// Deterministic CBOR orders map keys by their encoded bytes
  static int _byteOrder(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) {
        return a[i] - b[i];
      }
    }
    return a.length - b.length;
  }
}

class _Entry {
  final String key;
  final Object value;

  /// The key and the value, as the blob holds them
  final Uint8List bytes;
  final int keyLength;

  _Entry(this.key, this.value, this.bytes, [int? keyLength])
    : keyLength = keyLength ?? bytes.length - 1;

  Uint8List get encodedKey => Uint8List.sublistView(bytes, 0, keyLength);
}
