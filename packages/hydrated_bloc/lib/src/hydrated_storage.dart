import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:html' as html;

import 'package:hive/hive.dart';
// ignore: implementation_imports
import 'package:hive/src/hive_impl.dart';
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';

import 'hydrated_cipher.dart';

/// Interface which is used to persist and retrieve state changes.
abstract class Storage {
  /// Returns value for key
  dynamic read(String key);

  /// Persists key value pair
  Future<void> write(String key, dynamic value);

  /// Deletes key value pair
  Future<void> delete(String key);

  /// Clears all key value pairs from storage
  Future<void> clear();
}

/// {@template hydrated_storage}
/// Implementation of [Storage] which uses [package:hive](https://pub.dev/packages/hive)
/// to persist and retrieve state changes from the local device.
/// {@endtemplate}
class HydratedStorage implements Storage {
  /// {@macro hydrated_storage}
  @visibleForTesting
  HydratedStorage({
    Box<dynamic>? box,
    html.Storage? storage,
  })  : _box = box,
        _storage = storage;

  /// Sentinel directory used to determine that web storage should be used
  /// when initializing [HydratedStorage].
  ///
  /// ```dart
  /// await HydratedStorage.build(
  ///   storageDirectory: HydratedStorage.webStorageDirectory,
  /// );
  /// ```
  static final webStorageDirectory = Directory('');

  /// Returns an instance of [HydratedStorage].
  /// [storageDirectory] is required.
  ///
  /// For web, use [webStorageDirectory] as the `storageDirectory`
  ///
  /// ```dart
  /// import 'package:flutter/foundation.dart';
  /// import 'package:flutter/material.dart';
  ///
  /// import 'package:hydrated_bloc/hydrated_bloc.dart';
  /// import 'package:path_provider/path_provider.dart';
  ///
  /// void main() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   HydratedBloc.storage = await HydratedStorage.build(
  ///     storageDirectory: kIsWeb
  ///      ? HydratedStorage.webStorageDirectory
  ///      : await getTemporaryDirectory(),
  ///   );
  ///   runApp(App());
  /// }
  /// ```
  ///
  /// With [encryptionCipher] you can provide custom encryption.
  /// Following snippet shows how to make default one:
  /// ```dart
  /// import 'package:crypto/crypto.dart';
  /// import 'package:hydrated_bloc/hydrated_bloc.dart';
  ///
  /// const password = 'hydration';
  /// final byteskey = sha256.convert(utf8.encode(password)).bytes;
  /// return HydratedAesCipher(byteskey);
  /// ```
  static Future<HydratedStorage> build({
    required Directory storageDirectory,
    HydratedCipher? encryptionCipher,
  }) {
    return _lock.synchronized(() async {
      if (_instance != null) {
        print('Returning existing instance');
        return _instance!;
      }

      // Use HiveImpl directly to avoid conflicts with existing Hive.init
      // https://github.com/hivedb/hive/issues/336
      hive = HiveImpl();
      Box<dynamic>? box;
      html.Storage? storage;

      if (storageDirectory == webStorageDirectory) {
        try {
          print('Initialize hive');
          storage = html.window.sessionStorage;
          // box = await hive.openBox<dynamic>(
          //   'hydrated_box',
          //   encryptionCipher: encryptionCipher,
          // );
          // fallback to local storage should indexedDB of hive is
          // disabled on firefox private browsing
        } catch (err) {
          print('Cannot initialize hive. Falling back to localStorage');
        }
      } else {
        print('Initialize mobile app hive');
        hive.init(storageDirectory.path);
        box = await hive.openBox<dynamic>(
          'hydrated_box',
          encryptionCipher: encryptionCipher,
        );
        await _migrate(storageDirectory, box);
      }

      return _instance = HydratedStorage(box: box, storage: storage);
    }).onError((error, stackTrace) async {
      print('Goes here');
      return HydratedStorage();
    });
  }

  static Future _migrate(Directory directory, Box box) async {
    final file = File('${directory.path}/.hydrated_bloc.json');
    if (await file.exists()) {
      try {
        final dynamic storageJson = json.decode(await file.readAsString());
        final cache = (storageJson as Map).cast<String, String>();
        for (final key in cache.keys) {
          try {
            final string = cache[key];
            final dynamic object = json.decode(string ?? '');
            await box.put(key, object);
          } catch (_) {}
        }
      } catch (_) {}
      await file.delete();
    }
  }

  /// Internal instance of [HiveImpl].
  /// It should only be used for testing.
  @visibleForTesting
  static late HiveInterface hive;

  static final _lock = Lock();
  static HydratedStorage? _instance;

  late final Box? _box;
  late final html.Storage? _storage;

  @override
  dynamic read(String key) {
    if (_box?.isOpen ?? false) {
      print('Reading from box');
      return _box?.get(key);
    }

    if (_storage != null) {
      print('Reading from storage');
      return _storage!['key'] ?? null;
    }

    return null;
  }

  @override
  Future<void> write(String key, dynamic value) async {
    if (_box?.isOpen ?? false) {
      print('Writing to box');
      return _lock.synchronized(() => _box?.put(key, value));
    }

    if (_storage != null) {
      print('Writing to storage');
      return _lock.synchronized(() => _storage![key] = value.toString());
    }
  }

  @override
  Future<void> delete(String key) async {
    if (_box?.isOpen ?? false) {
      return _lock.synchronized(() => _box?.delete(key));
    }

    if (_storage != null) {
      return _lock.synchronized(() => _storage?.remove(key));
    }
  }

  @override
  Future<void> clear() async {
    if (_box?.isOpen ?? false) {
      _instance = null;
      return _lock.synchronized(_box!.clear);
    }

    if (_storage != null) {
      _instance = null;
      return _lock.synchronized(() => _storage?.clear());
    }
  }
}
