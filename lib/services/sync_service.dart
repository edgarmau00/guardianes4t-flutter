import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/local/db_api.dart';
import '../data/local/local_db.dart';
import '../data/models/promoted_record.dart';
import '../data/remote/api_service.dart';
import 'app_data_bus.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'network_status_service.dart';

class SyncService {
  static const int _statusPending = 0;
  static const int _statusSynced = 1;
  static const int _statusRejected = 2;
  static const int _statusRetry = 3;
  static Future<void>? _ongoingSync;

  Timer? _pollingTimer;
  bool? _lastInternetState;

  void startListening() {
    _pollingTimer?.cancel();
    unawaited(syncAll());
    _pollingTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      final hasInternet = await _hasInternet();
      final regainedInternet = _lastInternetState == false && hasInternet;
      _lastInternetState = hasInternet;

      if (regainedInternet) {
        await syncAll();
        return;
      }

      if (hasInternet) {
        await syncAll();
      }
    });
  }

  Future<void> syncAll() async {
    if (_ongoingSync != null) {
      return _ongoingSync!;
    }

    final completer = Completer<void>();
    _ongoingSync = completer.future;

    try {
      final hasInternet = await _hasInternet();
      if (!hasInternet || AuthService().currentUser == null) {
        return;
      }

      await _runSyncStep(syncPendingLeaders);
      await _runSyncStep(syncPendingPromoted);
      await _runSyncStep(syncPendingWhatsappGroups);
      await _runSyncStep(pullCurrentLeaderProfile);
      await _runSyncStep(pullRemotePromoted);
      await _runSyncStep(pullRemoteLeaders);
      await _runSyncStep(pullWhatsappGroups);
      AppDataBus.notify();
    } finally {
      completer.complete();
      _ongoingSync = null;
    }
  }

  Future<void> syncPendingPromoted() async {
    final uid = AuthService().currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    final db = await LocalDb.instance.database;
    final rows = await db.query(
      'promoted_records',
      where: 'capturist_id = ? AND sync_status IN (?, ?)',
      whereArgs: [uid, _statusPending, _statusRetry],
    );

    final remote = ApiService();

    for (final row in rows) {
      final record = PromotedRecord.fromMap(row);

      try {
        final existsRemote = await remote.promotedExistsByClaveElectoral(
          record.claveElectoral,
        );

        if (existsRemote) {
          await db.update(
            'promoted_records',
            {
              'sync_status': _statusRejected,
              'sync_message': 'Este ya se encuentra registrado',
            },
            where: 'local_id = ?',
            whereArgs: [record.localId],
          );
          continue;
        }

        final syncedRow = await remote.uploadPromoted(record);
        await _upsertSyncedRow(
          db: db,
          table: 'promoted_records',
          previousLocalId: record.localId,
          syncedRow: syncedRow,
        );
      } catch (e) {
        final resolution = _resolveSyncError(e);
        await db.update(
          'promoted_records',
          {
            'sync_status': resolution.status,
            'sync_message': resolution.message,
          },
          where: 'local_id = ?',
          whereArgs: [record.localId],
        );
      }
    }
  }

  Future<void> syncPendingLeaders() async {
    final uid = AuthService().currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    final db = await LocalDb.instance.database;
    final rows = await db.query(
      'leader_records',
      where: 'capturist_id = ? AND sync_status IN (?, ?)',
      whereArgs: [uid, _statusPending, _statusRetry],
    );

    final remote = ApiService();

    for (final row in rows) {
      try {
        var leaderRow = _normalizeLeaderRelationshipRow(
          Map<String, dynamic>.from(row),
        );
        final relationshipError = _validateLeaderRelationship(leaderRow);
        if (relationshipError != null) {
          await db.update(
            'leader_records',
            {
              'sync_status': _statusRejected,
              'sync_message': relationshipError,
            },
            where: 'local_id = ?',
            whereArgs: [row['local_id']],
          );
          continue;
        }

        final syncedRow = await remote.uploadLeader(leaderRow);
        await _upsertSyncedRow(
          db: db,
          table: 'leader_records',
          previousLocalId: (row['local_id'] ?? '').toString(),
          syncedRow: syncedRow,
        );
      } catch (e) {
        debugPrint(
          '[SYNC][LEADER] Error al sincronizar ${row['local_id']}: ${_buildSyncErrorMessage(e)}',
        );
        final resolution = _resolveSyncError(e);
        await db.update(
          'leader_records',
          {
            'sync_status': resolution.status,
            'sync_message': resolution.message,
          },
          where: 'local_id = ?',
          whereArgs: [row['local_id']],
        );
      }
    }
  }

  Future<void> syncPendingWhatsappGroups() async {
    final isAdmin = await ApiService().isCurrentUserAdmin();
    if (!isAdmin) return;

    final db = await LocalDb.instance.database;
    final rows = await db.query(
      'whatsapp_groups',
      where: 'sync_status IN (?, ?)',
      whereArgs: [_statusPending, _statusRetry],
    );

    final remote = ApiService();

    for (final row in rows) {
      try {
        final syncedRow = await remote.uploadWhatsappGroup(row);
        await db.update(
          'whatsapp_groups',
          syncedRow,
          where: 'local_id = ?',
          whereArgs: [row['local_id']],
        );
      } catch (e) {
        final resolution = _resolveSyncError(e);
        await db.update(
          'whatsapp_groups',
          {
            'sync_status': resolution.status,
            'sync_message': resolution.message,
          },
          where: 'local_id = ?',
          whereArgs: [row['local_id']],
        );
      }
    }
  }

  Future<void> pullRemotePromoted() async {
    final remote = ApiService();
    final rows = await remote.fetchPromotedByCurrentCapturist();
    final db = await LocalDb.instance.database;
    await _pruneMissingRemotePromoted(db: db, remoteRows: rows);

    for (final row in rows) {
      final localId = (row['local_id'] ?? '').toString().trim();
      if (await _shouldPreserveUnsyncedLocalRow(
        db: db,
        table: 'promoted_records',
        localId: localId,
      )) {
        continue;
      }

      await db.insert(
        'promoted_records',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<void> pullRemoteLeaders() async {
    final remote = ApiService();
    final rows = await remote.fetchLeadersByCurrentCapturist();
    final db = await LocalDb.instance.database;
    await _pruneMissingRemoteLeaders(db: db, remoteRows: rows);

    for (final row in rows) {
      final localId = (row['local_id'] ?? '').toString().trim();
      if (await _shouldPreserveUnsyncedLocalRow(
        db: db,
        table: 'leader_records',
        localId: localId,
      )) {
        continue;
      }

      final mergedRow = await _mergeLeaderRowWithLocalPassword(
        db: db,
        row: row,
      );
      await db.insert(
        'leader_records',
        mergedRow,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<void> _pruneMissingRemoteLeaders({
    required Database db,
    required List<Map<String, dynamic>> remoteRows,
  }) async {
    final uid = AuthService().currentUser?.uid ?? '';
    if (uid.isEmpty) {
      return;
    }

    final adminRole = await ApiService().fetchCurrentAdminRole();
    String sessionRole = 'unknown';
    if (adminRole.isNotEmpty) {
      sessionRole = adminRole;
    } else {
      final profile = await ApiService().fetchCurrentLeaderProfile();
      sessionRole = (profile?['leader_role'] ?? 'unknown').toString();
    }

    final remoteIds = remoteRows
        .map((row) => (row['local_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    String whereClause;
    List<Object?> whereArgs;

    if (sessionRole == 'superadmin') {
      whereClause = 'sync_status = ?';
      whereArgs = [_statusSynced];
    } else if (sessionRole == 'admin') {
      whereClause = 'owner_admin_user_id = ? AND sync_status = ?';
      whereArgs = [uid, _statusSynced];
    } else {
      whereClause = 'capturist_id = ? AND sync_status = ?';
      whereArgs = [uid, _statusSynced];
    }

    final localRows = await db.query(
      'leader_records',
      columns: ['local_id'],
      where: whereClause,
      whereArgs: whereArgs,
    );

    for (final row in localRows) {
      final localId = (row['local_id'] ?? '').toString().trim();
      if (localId.isEmpty || remoteIds.contains(localId)) {
        continue;
      }

      await db.delete(
        'leader_records',
        where: 'local_id = ?',
        whereArgs: [localId],
      );
    }
  }

  Future<void> pullCurrentLeaderProfile() async {
    final remote = ApiService();
    final row = await remote.fetchCurrentLeaderProfile();
    if (row == null) return;

    final db = await LocalDb.instance.database;
    final mergedRow = await _mergeLeaderRowWithLocalPassword(db: db, row: row);
    final localId = (mergedRow['local_id'] ?? '').toString().trim();
    if (await _shouldPreserveUnsyncedLocalRow(
      db: db,
      table: 'leader_records',
      localId: localId,
    )) {
      return;
    }

    await db.insert(
      'leader_records',
      mergedRow,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> pullWhatsappGroups() async {
    final rows = await ApiService().fetchWhatsappGroups();
    if (rows.isEmpty) return;

    final db = await LocalDb.instance.database;
    for (final row in rows) {
      final localId = (row['local_id'] ?? '').toString().trim();
      if (await _shouldPreserveUnsyncedLocalRow(
        db: db,
        table: 'whatsapp_groups',
        localId: localId,
      )) {
        continue;
      }

      await db.insert(
        'whatsapp_groups',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<bool> _hasInternet() async {
    return NetworkStatusService().hasInternet();
  }

  Future<void> _runSyncStep(Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      debugPrint('[SYNC] Step failed: ${_buildSyncErrorMessage(e)}');
    }
  }

  Future<void> _pruneMissingRemotePromoted({
    required Database db,
    required List<Map<String, dynamic>> remoteRows,
  }) async {
    final uid = AuthService().currentUser?.uid ?? '';
    if (uid.isEmpty) {
      return;
    }

    final adminRole = await ApiService().fetchCurrentAdminRole();
    String sessionRole = 'unknown';
    if (adminRole.isNotEmpty) {
      sessionRole = adminRole;
    } else {
      final profile = await ApiService().fetchCurrentLeaderProfile();
      sessionRole = (profile?['leader_role'] ?? 'unknown').toString();
    }

    final remoteIds = remoteRows
        .map((row) => (row['local_id'] ?? '').toString().trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    String whereClause;
    List<Object?> whereArgs;

    if (sessionRole == 'superadmin') {
      whereClause = 'sync_status = ?';
      whereArgs = [_statusSynced];
    } else if (sessionRole == 'leader_parent') {
      whereClause = 'owner_leader_auth_user_id = ? AND sync_status = ?';
      whereArgs = [uid, _statusSynced];
    } else if (sessionRole == 'admin') {
      whereClause = 'owner_admin_user_id = ? AND sync_status = ?';
      whereArgs = [uid, _statusSynced];
    } else {
      whereClause = 'capturist_id = ? AND sync_status = ?';
      whereArgs = [uid, _statusSynced];
    }

    final localRows = await db.query(
      'promoted_records',
      columns: ['local_id'],
      where: whereClause,
      whereArgs: whereArgs,
    );

    for (final row in localRows) {
      final localId = (row['local_id'] ?? '').toString().trim();
      if (localId.isEmpty || remoteIds.contains(localId)) {
        continue;
      }

      await db.delete(
        'promoted_records',
        where: 'local_id = ?',
        whereArgs: [localId],
      );
    }
  }

  Future<Map<String, dynamic>> _mergeLeaderRowWithLocalPassword({
    required Database db,
    required Map<String, dynamic> row,
  }) async {
    final localId = (row['local_id'] ?? '').toString().trim();
    if (localId.isEmpty) {
      return row;
    }

    final currentRows = await db.query(
      'leader_records',
      where: 'local_id = ? OR remote_id = ?',
      whereArgs: [localId, localId],
      limit: 1,
    );

    if (currentRows.isEmpty) {
      return row;
    }

    final current = currentRows.first;
    final existingPassword = (current['password'] ?? '').toString().trim();

    return {
      ...row,
      'password': existingPassword.isEmpty ? row['password'] : existingPassword,
    };
  }

  Future<void> _upsertSyncedRow({
    required Database db,
    required String table,
    required String previousLocalId,
    required Map<String, dynamic> syncedRow,
  }) async {
    final remoteId = (syncedRow['remote_id'] ?? syncedRow['local_id'] ?? '')
        .toString()
        .trim();

    if (remoteId.isEmpty || remoteId == previousLocalId) {
      await db.update(
        table,
        syncedRow,
        where: 'local_id = ?',
        whereArgs: [previousLocalId],
      );
      return;
    }

    final canonicalRow = {
      ...syncedRow,
      'local_id': remoteId,
      'remote_id': remoteId,
    };

    await db.delete(
      table,
      where: 'local_id = ? OR remote_id = ?',
      whereArgs: [remoteId, remoteId],
    );

    await db.delete(
      table,
      where: 'local_id = ?',
      whereArgs: [previousLocalId],
    );

    await db.insert(
      table,
      canonicalRow,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Map<String, dynamic> _normalizeLeaderRelationshipRow(
    Map<String, dynamic> row,
  ) {
    final localId = (row['local_id'] ?? '').toString().trim();
    final role = (row['leader_role'] ?? 'leader_parent').toString().trim();
    final fullName = (row['full_name'] ?? '').toString().trim();

    if (role == 'leader_parent') {
      return {
        ...row,
        'parent_leader_local_id': null,
        'parent_leader_remote_id': null,
        'parent_leader_auth_user_id': null,
        'parent_leader_name': null,
        'root_leader_local_id':
            (row['root_leader_local_id'] ?? '').toString().trim().isEmpty
                ? localId
                : row['root_leader_local_id'],
        'root_leader_remote_id':
            (row['root_leader_remote_id'] ?? '').toString().trim().isEmpty
                ? localId
                : row['root_leader_remote_id'],
        'root_leader_name':
            (row['root_leader_name'] ?? '').toString().trim().isEmpty
              ? fullName
              : row['root_leader_name'],
        'owner_admin_user_id': row['owner_admin_user_id'],
        'owner_admin_name': row['owner_admin_name'],
        'owner_admin_email': row['owner_admin_email'],
        'hierarchy_level': 1,
      };
    }

    return {
      ...row,
      'root_leader_local_id':
          (row['root_leader_local_id'] ?? '').toString().trim().isEmpty
              ? row['parent_leader_local_id']
              : row['root_leader_local_id'],
      'root_leader_remote_id':
          (row['root_leader_remote_id'] ?? '').toString().trim().isEmpty
              ? row['parent_leader_remote_id']
              : row['root_leader_remote_id'],
      'root_leader_auth_user_id':
          (row['root_leader_auth_user_id'] ?? '').toString().trim().isEmpty
              ? row['parent_leader_auth_user_id']
              : row['root_leader_auth_user_id'],
      'root_leader_name':
          (row['root_leader_name'] ?? '').toString().trim().isEmpty
              ? row['parent_leader_name']
              : row['root_leader_name'],
      'hierarchy_level': ((row['hierarchy_level'] as int?) ?? 0) < 2
          ? 2
          : row['hierarchy_level'],
    };
  }

  String? _validateLeaderRelationship(Map<String, dynamic> row) {
    final localId = (row['local_id'] ?? '').toString().trim();
    final role = (row['leader_role'] ?? '').toString().trim();
    final parentLocalId =
        (row['parent_leader_local_id'] ?? '').toString().trim();
    final parentAuthUserId =
        (row['parent_leader_auth_user_id'] ?? '').toString().trim();
    final rootLocalId = (row['root_leader_local_id'] ?? '').toString().trim();
    final rootRemoteId = (row['root_leader_remote_id'] ?? '').toString().trim();
    final rootLeaderName = (row['root_leader_name'] ?? '').toString().trim();
    final hierarchyLevel =
        int.tryParse((row['hierarchy_level'] ?? '0').toString()) ?? 0;

    if (localId.isEmpty) {
      return 'El lider no tiene identificador local';
    }

    if (role == 'leader_parent') {
      if (parentLocalId.isNotEmpty || parentAuthUserId.isNotEmpty) {
        return 'El lider no debe tener un padre asignado';
      }
      if (rootLocalId.isEmpty || rootRemoteId.isEmpty) {
        return 'El lider debe quedar ligado a si mismo como raiz';
      }
      if (hierarchyLevel != 1) {
        return 'El lider debe tener nivel jerarquico 1';
      }
      return null;
    }

    if (role != 'promoter') {
      return 'El rol del registro no es valido';
    }
    if (parentLocalId.isEmpty || parentAuthUserId.isEmpty) {
      return 'El promotor debe conservar la referencia del lider que lo registro';
    }
    if (rootLocalId.isEmpty || rootRemoteId.isEmpty || rootLeaderName.isEmpty) {
      return 'El promotor debe conservar la referencia del lider raiz';
    }
    if (parentLocalId == localId) {
      return 'El promotor no puede referenciarse a si mismo';
    }
    if (hierarchyLevel < 2) {
      return 'El promotor debe tener nivel jerarquico 2 o mayor';
    }

    return null;
  }

  void dispose() {
    _pollingTimer?.cancel();
  }

  Future<bool> _shouldPreserveUnsyncedLocalRow({
    required Database db,
    required String table,
    required String localId,
  }) async {
    if (localId.isEmpty) {
      return false;
    }

    final rows = await db.query(
      table,
      columns: ['sync_status'],
      where: 'local_id = ? OR remote_id = ?',
      whereArgs: [localId, localId],
      limit: 1,
    );

    if (rows.isEmpty) {
      return false;
    }

    final syncStatus = rows.first['sync_status'] as int? ?? _statusPending;
    return syncStatus == _statusPending || syncStatus == _statusRetry;
  }

  _SyncResolution _resolveSyncError(Object error) {
    final message = _buildSyncErrorMessage(error);
    if (_isPermanentSyncError(message)) {
      return _SyncResolution(_statusRejected, message);
    }

    return _SyncResolution(_statusRetry, message);
  }

  bool _isPermanentSyncError(String message) {
    return message == 'Este ya se encuentra registrado' ||
        message == 'La sesion no tiene permisos suficientes' ||
        message == 'El correo ya tiene un acceso creado' ||
        message == 'La contrasena del lider no es valida' ||
        message == 'El correo del lider no es valido';
  }

  String _buildSyncErrorMessage(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        return 'La sesion no tiene permisos suficientes';
      }
      if (error.statusCode == 409) {
        return 'Este ya se encuentra registrado';
      }
      return error.message;
    }

    final raw = error.toString().trim();
    if (raw.isEmpty) {
      return 'Pendiente por reintento de sincronizacion';
    }

    if (raw.contains('SocketException') ||
        raw.contains('Connection refused') ||
        raw.contains('timeout') ||
        raw.contains('connection') ||
        raw.contains('network')) {
      return 'Pendiente por reintento de sincronizacion';
    }

    if (raw.length > 180) {
      return raw.substring(0, 180);
    }

    return raw;
  }
}

class _SyncResolution {
  final int status;
  final String message;

  const _SyncResolution(this.status, this.message);
}
