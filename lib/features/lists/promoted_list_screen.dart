import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/local/db_api.dart';
import '../../data/local/local_db.dart';
import '../../data/remote/api_service.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';

class PromotedListScreen extends StatefulWidget {
  const PromotedListScreen({super.key});

  @override
  State<PromotedListScreen> createState() => _PromotedListScreenState();
}

class _PromotedListScreenState extends State<PromotedListScreen> {
  StreamSubscription<int>? _busSubscription;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _sessionRole = 'unknown';

  bool _isPrivilegedAdmin(String role) =>
      role == 'superadmin' || role == 'admin';

  Future<String> _resolveSessionRole() async {
    final uid = AuthService().currentUser?.uid ?? '';
    if (uid.isEmpty) return 'unknown';

    final db = await LocalDb.instance.database;
    final localRows = await db.query(
      'leader_records',
      where: 'auth_user_id = ?',
      whereArgs: [uid],
      limit: 1,
    );

    if (localRows.isNotEmpty) {
      return (localRows.first['leader_role'] ?? 'unknown').toString();
    }

    try {
      final adminRole = await ApiService().fetchCurrentAdminRole();
      if (adminRole.isNotEmpty) return adminRole;

      final remoteProfile = await ApiService().fetchCurrentLeaderProfile();
      if (remoteProfile != null) {
        await db.insert(
          'leader_records',
          remoteProfile,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return (remoteProfile['leader_role'] ?? 'unknown').toString();
      }
    } catch (_) {}

    return 'unknown';
  }

  Future<void> _load() async {
    try {
      await SyncService().pullRemotePromoted();
    } catch (_) {}

    final uid = AuthService().currentUser?.uid ?? '';
    final sessionRole = await _resolveSessionRole();
    final db = await LocalDb.instance.database;
    List<Map<String, dynamic>> rows = [];

    if (sessionRole == 'superadmin') {
      rows = _dedupePromotedRows(await db.query(
        'promoted_records',
        orderBy: 'created_at DESC',
      ));
    } else if (sessionRole == 'admin') {
      final allLeaderRows = _dedupeLeaderRows(await db.query('leader_records'));
      final parentRows = allLeaderRows
          .where(
            (row) =>
                (row['owner_admin_user_id'] ?? '').toString() == uid &&
                (row['leader_role'] ?? '').toString() == 'leader_parent',
          )
          .toList();
      final parentIds = parentRows
          .map((row) => (row['local_id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      final parentRemoteIds = parentRows
          .map((row) => (row['remote_id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toSet();
      final allPromotedRows = _dedupePromotedRows(await db.query(
        'promoted_records',
        orderBy: 'created_at DESC',
      ));

      rows = allPromotedRows.where((row) {
        final ownerAdminUserId =
            (row['owner_admin_user_id'] ?? '').toString();
        final ownerLocalId = (row['owner_leader_local_id'] ?? '').toString();
        final ownerRemoteId = (row['owner_leader_remote_id'] ?? '').toString();

        return ownerAdminUserId == uid ||
            parentIds.contains(ownerLocalId) ||
            parentIds.contains(ownerRemoteId) ||
            parentRemoteIds.contains(ownerRemoteId) ||
            parentRemoteIds.contains(ownerLocalId);
      }).toList();
    } else if (sessionRole == 'leader_parent') {
      rows = _dedupePromotedRows(await db.query(
        'promoted_records',
        where: 'owner_leader_auth_user_id = ?',
        whereArgs: [uid],
        orderBy: 'created_at DESC',
      ));
    } else {
      rows = _dedupePromotedRows(await db.query(
        'promoted_records',
        where: 'capturist_id = ?',
        whereArgs: [uid],
        orderBy: 'created_at DESC',
      ));
    }

    if (!mounted) return;

    setState(() {
      _sessionRole = sessionRole;
      _items = rows;
      _loading = false;
    });
  }

  List<Map<String, dynamic>> _dedupeLeaderRows(
      List<Map<String, dynamic>> rows) {
    final byKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final remoteId = (row['remote_id'] ?? '').toString().trim();
      final authUserId = (row['auth_user_id'] ?? '').toString().trim();
      final email = (row['email'] ?? '').toString().trim().toLowerCase();
      final role = (row['leader_role'] ?? '').toString().trim();
      final key = remoteId.isNotEmpty
          ? 'remote:$remoteId'
          : authUserId.isNotEmpty
              ? 'auth:$authUserId'
              : 'email:$role:$email';

      final current = byKey[key];
      if (current == null || _isBetterRow(row, current)) {
        byKey[key] = row;
      }
    }
    return byKey.values.toList();
  }

  List<Map<String, dynamic>> _dedupePromotedRows(
      List<Map<String, dynamic>> rows) {
    final byKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final remoteId = (row['remote_id'] ?? '').toString().trim();
      final clave =
          (row['clave_electoral'] ?? '').toString().trim().toUpperCase();
      final key = remoteId.isNotEmpty ? 'remote:$remoteId' : 'clave:$clave';

      final current = byKey[key];
      if (current == null || _isBetterRow(row, current)) {
        byKey[key] = row;
      }
    }
    return byKey.values.toList();
  }

  bool _isBetterRow(
      Map<String, dynamic> candidate, Map<String, dynamic> current) {
    final candidateSynced = (candidate['sync_status'] as int? ?? 0) == 1;
    final currentSynced = (current['sync_status'] as int? ?? 0) == 1;
    if (candidateSynced != currentSynced) {
      return candidateSynced;
    }

    final candidateRemote =
        (candidate['remote_id'] ?? '').toString().trim().isNotEmpty;
    final currentRemote =
        (current['remote_id'] ?? '').toString().trim().isNotEmpty;
    if (candidateRemote != currentRemote) {
      return candidateRemote;
    }

    final candidateCreatedAt = (candidate['created_at'] ?? '').toString();
    final currentCreatedAt = (current['created_at'] ?? '').toString();
    return candidateCreatedAt.compareTo(currentCreatedAt) >= 0;
  }

  String _statusLabel(int? status) {
    switch (status) {
      case 1:
        return 'Sincronizado';
      case 2:
        return 'Rechazado';
      case 3:
        return 'Reintento pendiente';
      default:
        return 'Pendiente';
    }
  }

  Color _statusColor(int? status) {
    switch (status) {
      case 1:
        return Colors.green;
      case 2:
        return Colors.red;
      case 3:
        return Colors.blue;
      default:
        return Colors.orange;
    }
  }

  @override
  void initState() {
    super.initState();
    _load();

    _busSubscription = AppDataBus.stream.listen((_) {
      _load();
    });
  }

  @override
  void dispose() {
    _busSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);
    final emptyLabel = _sessionRole == 'superadmin'
        ? 'No hay guardianes registrados'
        : _sessionRole == 'admin'
            ? 'No hay guardianes en tu estructura'
            : _sessionRole == 'leader_parent'
                ? 'No hay guardianes relacionados a tus promotores'
                : 'No hay guardianes registrados';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Guardianes registrados',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text(emptyLabel),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 24),
                  itemBuilder: (_, i) {
                    final item = _items[i];
                    final fullName =
                        '${item['nombre'] ?? ''} ${item['apellido_paterno'] ?? ''} ${item['apellido_materno'] ?? ''}'
                            .trim();

                    final syncStatus = item['sync_status'] as int?;
                    final syncMessage =
                        (item['sync_message'] ?? '').toString().trim();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fullName.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w500,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Clave de elector: ${item['clave_electoral'] ?? ''}',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'WhatsApp: ${item['whatsapp'] ?? item['telefono'] ?? ''}',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.black54,
                          ),
                        ),
                        if (_isPrivilegedAdmin(_sessionRole)) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Registrado por: ${(item['registered_by_user_email'] ?? '-').toString()}',
                            style: const TextStyle(
                              fontSize: 15,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                        if (_sessionRole == 'leader_parent') ...[
                          const SizedBox(height: 4),
                          Text(
                            'Pertenece a: ${(item['owner_leader_name'] ?? '-').toString()}',
                            style: const TextStyle(
                              fontSize: 15,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                        if (_isPrivilegedAdmin(_sessionRole)) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Pertenece a: ${(item['owner_leader_name'] ?? '-').toString()}',
                            style: const TextStyle(
                              fontSize: 15,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Text(
                          'Estado: ${_statusLabel(syncStatus)}',
                          style: TextStyle(
                            fontSize: 15,
                            color: _statusColor(syncStatus),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (syncMessage.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            syncMessage,
                            style: TextStyle(
                              fontSize: 14,
                              color: _statusColor(syncStatus),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
    );
  }
}
