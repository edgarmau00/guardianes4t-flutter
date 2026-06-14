import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../app/routes.dart';
import '../../data/local/local_db.dart';
import '../../data/remote/api_service.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';

class LeadersListScreen extends StatefulWidget {
  const LeadersListScreen({super.key});

  @override
  State<LeadersListScreen> createState() => _LeadersListScreenState();
}

class _LeadersListScreenState extends State<LeadersListScreen> {
  StreamSubscription<int>? _busSubscription;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String _sessionRole = 'unknown';
  String _adminScope = 'leaders';
  bool _didLoadRouteArgs = false;

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
      await SyncService().pullRemoteLeaders();
    } catch (_) {}

    final uid = AuthService().currentUser?.uid ?? '';
    final sessionRole = await _resolveSessionRole();
    final db = await LocalDb.instance.database;
    List<Map<String, dynamic>> rows = [];

    if (sessionRole == 'superadmin') {
      final allRows = _dedupeLeaderRows(await db.query(
        'leader_records',
        orderBy: 'created_at DESC',
      ));
      if (_adminScope == 'promoters') {
        rows = allRows
            .where((row) => (row['leader_role'] ?? '').toString() == 'promoter')
            .toList();
      } else {
        rows = allRows
            .where((row) =>
                (row['leader_role'] ?? '').toString() == 'leader_parent')
            .toList();
      }
    } else if (sessionRole == 'admin') {
      final allRows = _dedupeLeaderRows(await db.query(
        'leader_records',
        orderBy: 'created_at DESC',
      ));
      final parentRows = allRows
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

      if (_adminScope == 'promoters') {
        rows = allRows.where((row) {
          if ((row['leader_role'] ?? '').toString() != 'promoter') {
            return false;
          }

          final rootLocalId = (row['root_leader_local_id'] ?? '').toString();
          final rootRemoteId = (row['root_leader_remote_id'] ?? '').toString();
          return parentIds.contains(rootLocalId) ||
              parentIds.contains(rootRemoteId) ||
              parentRemoteIds.contains(rootRemoteId) ||
              parentRemoteIds.contains(rootLocalId);
        }).toList();
      } else {
        rows = parentRows;
      }
    } else if (sessionRole == 'leader_parent') {
      rows = _dedupeLeaderRows(await db.query(
        'leader_records',
        where: 'owner_leader_user_id = ? AND leader_role = ?',
        whereArgs: [uid, 'promoter'],
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoadRouteArgs) return;

    var shouldReload = false;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      final scope = (args['scope'] ?? '').toString();
      if (scope == 'leaders' || scope == 'promoters') {
        _adminScope = scope;
        shouldReload = true;
      }
    }
    _didLoadRouteArgs = true;
    if (shouldReload) {
      _load();
    }
  }

  @override
  void dispose() {
    _busSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);
    final title = _isPrivilegedAdmin(_sessionRole)
        ? (_adminScope == 'promoters'
            ? 'Promotores registrados'
            : 'Lideres registrados')
        : 'Promotores registrados';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          title,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_sessionRole == 'promoter' || _sessionRole == 'unknown')
              ? const Center(
                  child: Text('Tu rol no tiene acceso a esta seccion'),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Text('No hay registros disponibles'),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 24),
                      itemBuilder: (_, i) {
                        final item = _items[i];
                        final syncStatus = item['sync_status'] as int?;
                        final syncMessage =
                            (item['sync_message'] ?? '').toString().trim();

                        return InkWell(
                          onTap: () {
                            Navigator.pushNamed(
                              context,
                              AppRoutes.leaderDetail,
                              arguments: item,
                            );
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      (item['full_name'] ?? '')
                                          .toString()
                                          .toUpperCase(),
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.black87,
                                      ),
                                    ),
                                  ),
                                  if (_isPrivilegedAdmin(_sessionRole))
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF7A0C0C)
                                            .withValues(alpha: 0.10),
                                        borderRadius:
                                            BorderRadius.circular(999),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.edit_outlined,
                                            size: 16,
                                            color: Color(0xFF7A0C0C),
                                          ),
                                          SizedBox(width: 6),
                                          Text(
                                            'Editable',
                                            style: TextStyle(
                                              color: Color(0xFF7A0C0C),
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                              if (_isPrivilegedAdmin(_sessionRole)) ...[
                                const SizedBox(height: 8),
                                const Text(
                                  'Toca para editar acceso',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF7A0C0C),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              Text(
                                'Correo: ${item['email'] ?? ''}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Telefono: ${item['phone'] ?? ''}',
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 4),
                              if (!_isPrivilegedAdmin(_sessionRole) ||
                                  _adminScope == 'promoters') ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Rol: ${item['leader_role'] == 'leader_parent' ? 'Lider' : 'Promotor'}',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: Colors.black54,
                                  ),
                                ),
                              ],
                              if (_isPrivilegedAdmin(_sessionRole) &&
                                  (item['leader_role'] ?? '').toString() ==
                                      'promoter') ...[
                                const SizedBox(height: 4),
                                Text(
                                  'Pertenece a: ${(item['root_leader_name'] ?? item['parent_leader_name'] ?? '-').toString()}',
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
                          ),
                        );
                      },
                    ),
    );
  }
}
