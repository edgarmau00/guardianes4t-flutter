import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';

import 'db_api.dart';

class LocalDb {
  static final LocalDb instance = LocalDb._();
  LocalDb._();

  Database? _db;
  final _secureStorage = const FlutterSecureStorage();
  static const _dbPasswordKey = 'guardianes4t_db_password';

  Future<String> _getDbPassword() async {
    String? pass;
    try {
      pass = await _secureStorage.read(key: _dbPasswordKey);
    } on PlatformException {
      await _secureStorage.delete(key: _dbPasswordKey);
      pass = null;
    } catch (_) {
      await _secureStorage.delete(key: _dbPasswordKey);
      pass = null;
    }

    if (pass == null || pass.isEmpty) {
      pass = _generateSecureDbPassword();
      await _secureStorage.write(key: _dbPasswordKey, value: pass);
    }
    return pass;
  }

  String _generateSecureDbPassword() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  Future<Database> get database async {
    if (_db != null) return _db!;

    final databasesPath = await getDatabasesPath();
    final dbPath = join(databasesPath, 'guardianes4t.db');
    final legacyDbPath = join(databasesPath, 'electrascan.db');
    await _deleteLegacyDatabase(legacyDbPath);

    final dbPassword = await _getDbPassword();

    try {
      _db = await _openDatabaseWithPassword(dbPath, dbPassword);
    } catch (_) {
      await _resetLocalStorage(dbPath);
      final freshPassword = await _getDbPassword();
      _db = await _openDatabaseWithPassword(dbPath, freshPassword);
    }

    return _db!;
  }

  Future<void> _deleteLegacyDatabase(String legacyDbPath) async {
    try {
      await deleteDatabase(legacyDbPath);
    } catch (_) {}
  }

  Future<Database> _openDatabaseWithPassword(
    String dbPath,
    String password,
  ) async {
    return openDatabase(
      dbPath,
      password: password,
      version: 8,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE promoted_records (
            local_id TEXT PRIMARY KEY,
            remote_id TEXT,
            capturist_id TEXT NOT NULL,
            registered_by_user_id TEXT,
            registered_by_user_email TEXT,
            owner_admin_user_id TEXT,
            owner_admin_name TEXT,
            owner_admin_email TEXT,
            owner_leader_local_id TEXT,
            owner_leader_remote_id TEXT,
            owner_leader_auth_user_id TEXT,
            owner_leader_name TEXT,
            owner_promoter_user_id TEXT,
            owner_promoter_name TEXT,
            image_path TEXT,
            clave_electoral TEXT,
            sexo TEXT,
            nombre TEXT,
            apellido_paterno TEXT,
            apellido_materno TEXT,
            direccion TEXT,
            codigo_postal TEXT,
            vigencia TEXT,
            seccion_electoral TEXT,
            fecha_nacimiento TEXT,
            curp TEXT,
            estado TEXT,
            municipio TEXT,
            telefono TEXT,
            whatsapp TEXT,
            discapacidad INTEGER,
            sync_status INTEGER,
            sync_message TEXT,
            created_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE leader_records (
            local_id TEXT PRIMARY KEY,
            remote_id TEXT,
            capturist_id TEXT NOT NULL,
            registered_by_user_id TEXT,
            registered_by_user_email TEXT,
            registered_by_user_name TEXT,
            owner_admin_user_id TEXT,
            owner_admin_name TEXT,
            owner_admin_email TEXT,
            auth_user_id TEXT,
            leader_role TEXT,
            parent_leader_local_id TEXT,
            parent_leader_remote_id TEXT,
            parent_leader_auth_user_id TEXT,
            parent_leader_name TEXT,
            root_leader_local_id TEXT,
            root_leader_remote_id TEXT,
            root_leader_auth_user_id TEXT,
            root_leader_name TEXT,
            hierarchy_level INTEGER,
            email TEXT,
            password TEXT,
            full_name TEXT,
            phone TEXT,
            sync_status INTEGER,
            sync_message TEXT,
            created_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE whatsapp_groups (
            local_id TEXT PRIMARY KEY,
            remote_id TEXT,
            name TEXT NOT NULL,
            invite_link TEXT NOT NULL,
            notes TEXT,
            active INTEGER,
            created_by_user_id TEXT,
            created_by_user_email TEXT,
            sync_status INTEGER,
            sync_message TEXT,
            created_at TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN sync_message TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN sync_message TEXT",
          );
        }
        if (oldVersion < 3) {
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN registered_by_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN registered_by_user_email TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_leader_local_id TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_leader_remote_id TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_leader_name TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN registered_by_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN registered_by_user_email TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN registered_by_user_name TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN parent_leader_local_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN parent_leader_remote_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN parent_leader_name TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN hierarchy_level INTEGER DEFAULT 1",
          );
        }
        if (oldVersion < 4) {
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN auth_user_id TEXT",
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN leader_role TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN parent_leader_auth_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN root_leader_local_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN root_leader_remote_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN root_leader_auth_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN root_leader_name TEXT",
          );
        }
        if (oldVersion < 6) {
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_leader_auth_user_id TEXT",
          );
        }
        if (oldVersion < 7) {
          await db.execute('''
            CREATE TABLE whatsapp_groups (
              local_id TEXT PRIMARY KEY,
              remote_id TEXT,
              name TEXT NOT NULL,
              invite_link TEXT NOT NULL,
              notes TEXT,
              active INTEGER,
              created_by_user_id TEXT,
              created_by_user_email TEXT,
              sync_status INTEGER,
              sync_message TEXT,
              created_at TEXT
            )
          ''');
        }
        if (oldVersion < 8) {
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_admin_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_admin_name TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_admin_email TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_promoter_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE promoted_records ADD COLUMN owner_promoter_name TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN owner_admin_user_id TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN owner_admin_name TEXT",
          );
          await db.execute(
            "ALTER TABLE leader_records ADD COLUMN owner_admin_email TEXT",
          );
        }
      },
    );
  }

  Future<void> _resetLocalStorage(String dbPath) async {
    try {
      await _db?.close();
    } catch (_) {}

    _db = null;
    await _secureStorage.delete(key: _dbPasswordKey);
    await deleteDatabase(dbPath);
  }
}
