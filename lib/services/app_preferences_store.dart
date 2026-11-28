import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/app_preferences.dart';

abstract class AppPreferencesStore {
  Future<AppPreferences> load();

  Future<void> save(AppPreferences preferences);
}

/// Atomic JSON file-backed repository for [AppPreferences].
class FileAppPreferencesStore implements AppPreferencesStore {
  FileAppPreferencesStore({
    Future<Directory> Function()? baseDirProvider,
  }) : _baseDirProvider = baseDirProvider ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _baseDirProvider;

  Future<Directory> _rootDir() async {
    final base = await _baseDirProvider();
    final root = Directory('${base.path}${Platform.pathSeparator}unclip_prefs');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  File _prefsFile(Directory root) =>
      File('${root.path}${Platform.pathSeparator}preferences.json');

  @override
  Future<AppPreferences> load() async {
    try {
      final root = await _rootDir();
      final file = _prefsFile(root);
      if (!await file.exists()) {
        return AppPreferences.defaults;
      }
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return AppPreferences.defaults;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return AppPreferences.defaults;
      }
      return AppPreferences.fromJson(Map<Object?, Object?>.from(decoded));
    } catch (_) {
      return AppPreferences.defaults;
    }
  }

  @override
  Future<void> save(AppPreferences preferences) async {
    try {
      final root = await _rootDir();
      final target = _prefsFile(root);
      final tmp = File('${target.path}.tmp');
      final payload = jsonEncode(preferences.toJson());
      await tmp.writeAsString(payload, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        await tmp.copy(target.path);
        if (await tmp.exists()) {
          await tmp.delete();
        }
      }
    } catch (_) {
      // Best-effort preferences persistence.
    }
  }
}

class InMemoryAppPreferencesStore implements AppPreferencesStore {
  InMemoryAppPreferencesStore([this._preferences = AppPreferences.defaults]);

  AppPreferences _preferences;

  @override
  Future<AppPreferences> load() async => _preferences;

  @override
  Future<void> save(AppPreferences preferences) async {
    _preferences = preferences;
  }
}
