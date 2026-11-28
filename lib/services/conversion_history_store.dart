import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../models/conversion_history.dart';

abstract class ConversionHistoryStore {
  Future<List<ConversionHistoryEntry>> load();

  Future<List<ConversionHistoryEntry>> add(
    ConversionHistoryEntry entry, {
    Uint8List? thumbnailBytes,
    String? customCoverSourcePath,
  });

  Future<List<ConversionHistoryEntry>> removeById(String id);

  Future<void> clear();

  Future<int> calculateStorageBytes();
}

/// JSON + thumbnail file-backed history repository capped at [maxEntries].
class FileConversionHistoryStore implements ConversionHistoryStore {
  FileConversionHistoryStore({
    Future<Directory> Function()? baseDirProvider,
  }) : _baseDirProvider = baseDirProvider ?? getApplicationDocumentsDirectory;

  static const int maxEntries = 30;

  final Future<Directory> Function() _baseDirProvider;

  Future<Directory> _rootDir() async {
    final base = await _baseDirProvider();
    final root = Directory('${base.path}${Platform.pathSeparator}unclip_history');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> _thumbsDir(Directory root) async {
    final thumbs = Directory('${root.path}${Platform.pathSeparator}thumbs');
    if (!await thumbs.exists()) {
      await thumbs.create(recursive: true);
    }
    return thumbs;
  }

  File _historyFile(Directory root) =>
      File('${root.path}${Platform.pathSeparator}history.json');

  String _safeFileStem(String rawId) {
    final cleaned = rawId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return cleaned.isEmpty ? 'entry' : cleaned;
  }

  String _safeImageExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '.jpg';
    final ext = path.substring(dot).toLowerCase();
    switch (ext) {
      case '.jpg':
      case '.jpeg':
      case '.png':
      case '.heic':
      case '.webp':
        return ext;
      default:
        return '.jpg';
    }
  }

  Future<void> _deleteThumbnailIfManaged(
    Directory thumbsDir,
    String? path,
  ) async {
    if (path == null || path.isEmpty) return;
    try {
      final thumbsPrefix = thumbsDir.path;
      if (!path.startsWith(thumbsPrefix)) return;
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort cleanup of stale thumbnail files.
    }
  }

  Future<void> _writeAtomically(
    Directory root,
    List<ConversionHistoryEntry> entries,
  ) async {
    final target = _historyFile(root);
    final tmp = File('${target.path}.tmp');
    final payload = jsonEncode(
      entries.map((ConversionHistoryEntry e) => e.toJson()).toList(),
    );
    await tmp.writeAsString(payload, flush: true);
    try {
      await tmp.rename(target.path);
    } catch (_) {
      await tmp.copy(target.path);
      if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  @override
  Future<List<ConversionHistoryEntry>> load() async {
    try {
      final root = await _rootDir();
      final file = _historyFile(root);
      if (!await file.exists()) {
        return const <ConversionHistoryEntry>[];
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const <ConversionHistoryEntry>[];
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const <ConversionHistoryEntry>[];
      }
      final entries = <ConversionHistoryEntry>[];
      for (final item in decoded) {
        if (item is Map) {
          final entry = ConversionHistoryEntry.fromJson(
            Map<Object?, Object?>.from(item),
          );
          if (entry.id.isNotEmpty) {
            entries.add(entry);
          }
        }
      }
      entries.sort(
        (ConversionHistoryEntry a, ConversionHistoryEntry b) =>
            b.createdAtMs.compareTo(a.createdAtMs),
      );
      return entries;
    } catch (_) {
      return const <ConversionHistoryEntry>[];
    }
  }

  @override
  Future<List<ConversionHistoryEntry>> add(
    ConversionHistoryEntry entry, {
    Uint8List? thumbnailBytes,
    String? customCoverSourcePath,
  }) async {
    final root = await _rootDir();
    final thumbs = await _thumbsDir(root);

    var storedEntry = entry;
    if (thumbnailBytes != null && thumbnailBytes.isNotEmpty) {
      final thumbFile = File(
        '${thumbs.path}${Platform.pathSeparator}${_safeFileStem(entry.id)}.jpg',
      );
      await thumbFile.writeAsBytes(thumbnailBytes, flush: true);
      storedEntry = entry.copyWith(thumbnailPath: thumbFile.path);
    } else {
      final coverSrc =
          (customCoverSourcePath != null && customCoverSourcePath.isNotEmpty)
              ? customCoverSourcePath
              : entry.customCoverPath;
      if (coverSrc != null && coverSrc.isNotEmpty) {
        try {
          final srcFile = File(coverSrc);
          if (await srcFile.exists()) {
            final ext = _safeImageExtension(coverSrc);
            final thumbFile = File(
              '${thumbs.path}${Platform.pathSeparator}${_safeFileStem(entry.id)}$ext',
            );
            await srcFile.copy(thumbFile.path);
            storedEntry = entry.copyWith(thumbnailPath: thumbFile.path);
          }
        } catch (_) {
          // Best-effort custom cover persistence.
        }
      }
    }

    final existing = await load();
    final merged = <ConversionHistoryEntry>[
      storedEntry,
      ...existing.where((ConversionHistoryEntry e) => e.id != storedEntry.id),
    ];
    merged.sort(
      (ConversionHistoryEntry a, ConversionHistoryEntry b) =>
          b.createdAtMs.compareTo(a.createdAtMs),
    );

    if (merged.length > maxEntries) {
      final evicted = merged.sublist(maxEntries);
      for (final old in evicted) {
        await _deleteThumbnailIfManaged(thumbs, old.thumbnailPath);
      }
    }

    final capped = merged.take(maxEntries).toList(growable: false);
    await _writeAtomically(root, capped);
    return capped;
  }

  @override
  Future<List<ConversionHistoryEntry>> removeById(String id) async {
    final root = await _rootDir();
    final thumbs = await _thumbsDir(root);
    final existing = await load();
    final kept = <ConversionHistoryEntry>[];

    for (final entry in existing) {
      if (entry.id == id) {
        await _deleteThumbnailIfManaged(thumbs, entry.thumbnailPath);
      } else {
        kept.add(entry);
      }
    }

    await _writeAtomically(root, kept);
    return kept;
  }

  @override
  Future<void> clear() async {
    try {
      final root = await _rootDir();
      final file = _historyFile(root);
      if (await file.exists()) {
        await file.delete();
      }
      final thumbs = await _thumbsDir(root);
      if (await thumbs.exists()) {
        await for (final entity in thumbs.list()) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {
            // Ignore locked or already-removed items.
          }
        }
      }
    } catch (_) {
      // Ignore cleanup errors.
    }
  }

  @override
  Future<int> calculateStorageBytes() async {
    try {
      final root = await _rootDir();
      var total = 0;
      final file = _historyFile(root);
      if (await file.exists()) {
        total += await file.length();
      }
      final thumbs = await _thumbsDir(root);
      if (await thumbs.exists()) {
        await for (final entity in thumbs.list()) {
          if (entity is File) {
            try {
              total += await entity.length();
            } catch (_) {
              // Ignore disappearing temp files.
            }
          }
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

class InMemoryConversionHistoryStore implements ConversionHistoryStore {
  InMemoryConversionHistoryStore([List<ConversionHistoryEntry>? initial])
      : _entries = List<ConversionHistoryEntry>.from(
          initial ?? const <ConversionHistoryEntry>[],
        );

  final List<ConversionHistoryEntry> _entries;

  @override
  Future<List<ConversionHistoryEntry>> load() async {
    final copy = List<ConversionHistoryEntry>.from(_entries);
    copy.sort(
      (ConversionHistoryEntry a, ConversionHistoryEntry b) =>
          b.createdAtMs.compareTo(a.createdAtMs),
    );
    return copy;
  }

  @override
  Future<List<ConversionHistoryEntry>> add(
    ConversionHistoryEntry entry, {
    Uint8List? thumbnailBytes,
    String? customCoverSourcePath,
  }) async {
    _entries.removeWhere((ConversionHistoryEntry e) => e.id == entry.id);
    _entries.insert(0, entry);
    if (_entries.length > FileConversionHistoryStore.maxEntries) {
      _entries.removeRange(
        FileConversionHistoryStore.maxEntries,
        _entries.length,
      );
    }
    return load();
  }

  @override
  Future<List<ConversionHistoryEntry>> removeById(String id) async {
    _entries.removeWhere((ConversionHistoryEntry e) => e.id == id);
    return load();
  }

  @override
  Future<void> clear() async {
    _entries.clear();
  }

  @override
  Future<int> calculateStorageBytes() async {
    if (_entries.isEmpty) return 0;
    var total = 0;
    for (final entry in _entries) {
      total += (entry.thumbnailPath != null && entry.thumbnailPath!.isNotEmpty)
          ? 128 * 1024
          : 4 * 1024;
    }
    return total;
  }
}
