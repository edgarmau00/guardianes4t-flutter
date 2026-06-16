import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../app/routes.dart';
import '../../data/local/local_db.dart';
import '../../data/remote/api_service.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/dashboard_card.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  StreamSubscription<int>? _busSubscription;

  int guardiansRegistered = 0;
  int leadersRegistered = 0;
  int promotersRegistered = 0;
  int guardiansPending = 0;
  int leadersPending = 0;
  int promotersPending = 0;
  int guardiansRejected = 0;
  int leadersRejected = 0;
  int promotersRejected = 0;
  int whatsappGroupsRegistered = 0;

  bool loading = true;
  String _sessionRole = 'unknown';

  bool _isPrivilegedAdmin(String role) =>
      role == 'superadmin' || role == 'admin';

  @override
  void initState() {
    super.initState();
    _loadStats();

    _busSubscription = AppDataBus.stream.listen((_) {
      _loadStats();
    });
  }

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

  Future<void> _loadStats() async {
    final uid = AuthService().currentUser?.uid ?? '';
    final sessionRole = await _resolveSessionRole();
    final db = await LocalDb.instance.database;

    int nextLeadersRegistered = 0;
    int nextLeadersPending = 0;
    int nextLeadersRejected = 0;
    int nextPromotersRegistered = 0;
    int nextPromotersPending = 0;
    int nextPromotersRejected = 0;
    int nextGuardiansRegistered = 0;
    int nextGuardiansPending = 0;
    int nextGuardiansRejected = 0;
    int nextWhatsappGroupsRegistered = 0;

    if (sessionRole == 'superadmin') {
      final promotedRows =
          _dedupePromotedRows(await db.query('promoted_records'));
      final allRows = _dedupeLeaderRows(await db.query('leader_records'));
      final parentRows = allRows
          .where(
            (row) => (row['leader_role'] ?? '').toString() == 'leader_parent',
          )
          .toList();
      final promoterRows = allRows
          .where((row) => (row['leader_role'] ?? '').toString() == 'promoter')
          .toList();

      nextLeadersRegistered = parentRows.length;
      nextLeadersPending =
          parentRows.where((row) => [0, 3].contains(row['sync_status'])).length;
      nextLeadersRejected =
          parentRows.where((row) => row['sync_status'] == 2).length;
      nextPromotersRegistered = promoterRows.length;
      nextPromotersPending = promoterRows
          .where((row) => [0, 3].contains(row['sync_status']))
          .length;
      nextPromotersRejected =
          promoterRows.where((row) => row['sync_status'] == 2).length;
      nextGuardiansRegistered = promotedRows.length;
      nextGuardiansPending = promotedRows
          .where((row) => [0, 3].contains(row['sync_status']))
          .length;
      nextGuardiansRejected =
          promotedRows.where((row) => row['sync_status'] == 2).length;
    } else if (sessionRole == 'admin') {
      final promotedRows =
          _dedupePromotedRows(await db.query('promoted_records'));
      final allRows = _dedupeLeaderRows(await db.query('leader_records'));
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

      final promoterRows = allRows.where((row) {
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

      final managedGuardianRows = promotedRows.where((row) {
        final ownerAdminUserId = (row['owner_admin_user_id'] ?? '').toString();
        final ownerLocalId = (row['owner_leader_local_id'] ?? '').toString();
        final ownerRemoteId = (row['owner_leader_remote_id'] ?? '').toString();

        return ownerAdminUserId == uid ||
            parentIds.contains(ownerLocalId) ||
            parentIds.contains(ownerRemoteId) ||
            parentRemoteIds.contains(ownerRemoteId) ||
            parentRemoteIds.contains(ownerLocalId);
      }).toList();

      nextLeadersRegistered = parentRows.length;
      nextLeadersPending =
          parentRows.where((row) => [0, 3].contains(row['sync_status'])).length;
      nextLeadersRejected =
          parentRows.where((row) => row['sync_status'] == 2).length;
      nextPromotersRegistered = promoterRows.length;
      nextPromotersPending = promoterRows
          .where((row) => [0, 3].contains(row['sync_status']))
          .length;
      nextPromotersRejected =
          promoterRows.where((row) => row['sync_status'] == 2).length;
      nextGuardiansRegistered = managedGuardianRows.length;
      nextGuardiansPending = managedGuardianRows
          .where((row) => [0, 3].contains(row['sync_status']))
          .length;
      nextGuardiansRejected =
          managedGuardianRows.where((row) => row['sync_status'] == 2).length;
    } else if (sessionRole == 'leader_parent') {
      final promotedRows = _dedupePromotedRows(
        await db.query('promoted_records', orderBy: 'created_at DESC'),
      );
      final leaderRows = _dedupeLeaderRows(
        await db.query('leader_records', orderBy: 'created_at DESC'),
      );

      final managedGuardians = promotedRows
          .where((row) =>
              (row['owner_leader_auth_user_id'] ?? '').toString() == uid)
          .toList();
      final promoters = leaderRows
          .where((row) =>
              (row['owner_leader_user_id'] ?? '').toString() == uid &&
              (row['leader_role'] ?? '').toString() == 'promoter')
          .toList();

      nextGuardiansRegistered = managedGuardians.length;
      nextGuardiansPending = managedGuardians
          .where((row) => [0, 3].contains(row['sync_status']))
          .length;
      nextGuardiansRejected =
          managedGuardians.where((row) => row['sync_status'] == 2).length;
      nextLeadersRegistered = promoters.length;
      nextLeadersPending =
          promoters.where((row) => [0, 3].contains(row['sync_status'])).length;
      nextLeadersRejected =
          promoters.where((row) => row['sync_status'] == 2).length;
    } else {
      final promotedRows = _dedupePromotedRows(
        await db.query('promoted_records', orderBy: 'created_at DESC'),
      );
      final mine = promotedRows
          .where((row) => (row['capturist_id'] ?? '').toString() == uid)
          .toList();
      nextGuardiansRegistered = mine.length;
      nextGuardiansPending =
          mine.where((row) => [0, 3].contains(row['sync_status'])).length;
      nextGuardiansRejected =
          mine.where((row) => row['sync_status'] == 2).length;
    }

    if (_isPrivilegedAdmin(sessionRole)) {
      final whatsappGroupsTotal = await db.rawQuery(
        'SELECT COUNT(*) as total FROM whatsapp_groups',
      );
      nextWhatsappGroupsRegistered =
          (whatsappGroupsTotal.first['total'] as int?) ?? 0;
    }

    if (!mounted) return;

    setState(() {
      _sessionRole = sessionRole;
      guardiansRegistered = nextGuardiansRegistered;
      guardiansPending = nextGuardiansPending;
      guardiansRejected = nextGuardiansRejected;
      leadersRegistered = nextLeadersRegistered;
      leadersPending = nextLeadersPending;
      leadersRejected = nextLeadersRejected;
      promotersRegistered = nextPromotersRegistered;
      promotersPending = nextPromotersPending;
      promotersRejected = nextPromotersRejected;
      whatsappGroupsRegistered = nextWhatsappGroupsRegistered;
      loading = false;
    });
  }

  List<Map<String, dynamic>> _dedupeLeaderRows(
      List<Map<String, dynamic>> rows) {
    final byKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final key = _leaderKey(row);
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
      final key = _promotedKey(row);
      final current = byKey[key];
      if (current == null || _isBetterRow(row, current)) {
        byKey[key] = row;
      }
    }
    return byKey.values.toList();
  }

  String _leaderKey(Map<String, dynamic> row) {
    final remoteId = (row['remote_id'] ?? '').toString().trim();
    if (remoteId.isNotEmpty) return 'remote:$remoteId';
    final authUserId = (row['auth_user_id'] ?? '').toString().trim();
    if (authUserId.isNotEmpty) return 'auth:$authUserId';
    final email = (row['email'] ?? '').toString().trim().toLowerCase();
    final role = (row['leader_role'] ?? '').toString().trim();
    return 'email:$role:$email';
  }

  String _promotedKey(Map<String, dynamic> row) {
    final remoteId = (row['remote_id'] ?? '').toString().trim();
    if (remoteId.isNotEmpty) return 'remote:$remoteId';
    final clave =
        (row['clave_electoral'] ?? '').toString().trim().toUpperCase();
    return 'clave:$clave';
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

  Future<void> _logout(BuildContext context) async {
    await AuthService().logout();
    if (!context.mounted) return;
    Navigator.pushReplacementNamed(context, AppRoutes.login);
  }

  Future<void> _sync(BuildContext context) async {
    await SyncService().syncAll();
    await _loadStats();

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sincronizacion completada'),
        content: const Text(
          'Los registros pendientes se sincronizaron correctamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  String get _roleLabel {
    switch (_sessionRole) {
      case 'superadmin':
        return 'Superadmin';
      case 'admin':
        return 'Admin';
      case 'leader_parent':
        return 'Lider';
      case 'promoter':
        return 'Promotor';
      default:
        return 'Usuario';
    }
  }

  void _openBottomMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(28),
        ),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isPrivilegedAdmin(_sessionRole) ||
                  _sessionRole == 'leader_parent')
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7B1E2B).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.person_add_alt_1_rounded,
                      color: Color(0xFF7B1E2B),
                    ),
                  ),
                  title: Text(
                    _isPrivilegedAdmin(_sessionRole)
                        ? 'Agregar lider'
                        : 'Agregar promotor',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    _isPrivilegedAdmin(_sessionRole)
                        ? 'Registrar un nuevo lider'
                        : 'Registrar un nuevo promotor',
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, AppRoutes.leaderForm);
                  },
                ),
              if (_isPrivilegedAdmin(_sessionRole) ||
                  _sessionRole == 'leader_parent')
                const SizedBox(height: 8),
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7B1E2B).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.group_add_rounded,
                    color: Color(0xFF7B1E2B),
                  ),
                ),
                title: const Text(
                  'Agregar guardian',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Iniciar flujo de captura'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, AppRoutes.captureMenu);
                },
              ),
              if (_isPrivilegedAdmin(_sessionRole)) ...[
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7B1E2B).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.forum_rounded,
                      color: Color(0xFF7B1E2B),
                    ),
                  ),
                  title: const Text(
                    'Grupos de WhatsApp',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('Ver y administrar grupos'),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(context, AppRoutes.whatsappGroups);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _busSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7B1E2B);
    final width = MediaQuery.of(context).size.width;
    final compact = width <= 390;
    final iosTight = Platform.isIOS && width <= 430;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel principal'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesion',
            onPressed: () => _logout(context),
            icon: const Icon(Icons.logout_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openBottomMenu(context),
        child: const Icon(Icons.add_rounded),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 16,
                  8,
                  compact ? 14 : 16,
                  100,
                ),
                children: [
                  Container(
                    padding: EdgeInsets.all(compact ? 18 : 20),
                    decoration: BoxDecoration(
                      color: primary,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Guardianes4T',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Rol activo: $_roleLabel',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _sessionRole == 'superadmin'
                              ? 'Control total de la plataforma y visibilidad completa de toda la estructura.'
                              : _sessionRole == 'admin'
                                  ? 'Administra lideres y registra guardianes cuando sea necesario.'
                                  : _sessionRole == 'leader_parent'
                                      ? 'Administra promotores y da seguimiento a los guardianes de tu estructura.'
                                      : 'Registra y consulta unicamente tus guardianes.',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding:
                        EdgeInsets.all(iosTight ? 16 : (compact ? 14 : 16)),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: iosTight
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    height: 46,
                                    width: 46,
                                    decoration: BoxDecoration(
                                      color: primary.withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: const Icon(
                                      Icons.sync_rounded,
                                      color: primary,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Sincronizacion',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF111827),
                                          ),
                                        ),
                                        SizedBox(height: 4),
                                        Text(
                                          'Envia los registros locales al servidor',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: Color(0xFF6B7280),
                                            height: 1.35,
                                          ),
                                          maxLines: 2,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () => _sync(context),
                                  style: ElevatedButton.styleFrom(
                                    minimumSize: const Size.fromHeight(48),
                                  ),
                                  child: const Text('Sincronizar'),
                                ),
                              ),
                            ],
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Container(
                                height: compact ? 42 : 46,
                                width: compact ? 42 : 46,
                                decoration: BoxDecoration(
                                  color: primary.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: const Icon(
                                  Icons.sync_rounded,
                                  color: primary,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Sincronizacion',
                                      style: TextStyle(
                                        fontSize: compact ? 15 : 16,
                                        fontWeight: FontWeight.w800,
                                        color: const Color(0xFF111827),
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Envia los registros locales al servidor',
                                      style: TextStyle(
                                        fontSize: compact ? 12 : 13,
                                        color: const Color(0xFF6B7280),
                                      ),
                                      maxLines: compact ? 4 : 3,
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: compact ? 10 : 12),
                              ElevatedButton(
                                onPressed: () => _sync(context),
                                style: ElevatedButton.styleFrom(
                                  minimumSize: Size(compact ? 96 : 110, 46),
                                  padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 12 : 16,
                                  ),
                                ),
                                child: const Text('Sincronizar'),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    'Resumen general',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 14),
                  GridView.count(
                    crossAxisCount: 2,
                    crossAxisSpacing: iosTight ? 10 : (compact ? 12 : 14),
                    mainAxisSpacing: iosTight ? 10 : (compact ? 12 : 14),
                    childAspectRatio: iosTight ? 0.74 : (compact ? 0.84 : 0.92),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      DashboardCard(
                        title: 'Guardianes registrados',
                        value: guardiansRegistered.toString(),
                        color: const Color(0xFF16A34A),
                        icon: Icons.groups_rounded,
                        onTap: () => Navigator.pushNamed(
                            context, AppRoutes.promotedList),
                      ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Lideres registrados',
                          value: leadersRegistered.toString(),
                          color: const Color(0xFF0EA5E9),
                          icon: Icons.badge_rounded,
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.leadersList,
                            arguments: {'scope': 'leaders'},
                          ),
                        ),
                      if (_sessionRole == 'leader_parent')
                        DashboardCard(
                          title: 'Promotores registrados',
                          value: leadersRegistered.toString(),
                          color: const Color(0xFF0EA5E9),
                          icon: Icons.badge_rounded,
                          onTap: () => Navigator.pushNamed(
                              context, AppRoutes.leadersList),
                        ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Promotores registrados',
                          value: promotersRegistered.toString(),
                          color: const Color(0xFF2563EB),
                          icon: Icons.manage_accounts_rounded,
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.leadersList,
                            arguments: {'scope': 'promoters'},
                          ),
                        ),
                      DashboardCard(
                        title: 'Guardianes pendientes',
                        value: guardiansPending.toString(),
                        color: const Color(0xFFF59E0B),
                        icon: Icons.sync_rounded,
                      ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Lideres pendientes',
                          value: leadersPending.toString(),
                          color: const Color(0xFFF97316),
                          icon: Icons.hourglass_top_rounded,
                        ),
                      if (_sessionRole == 'leader_parent')
                        DashboardCard(
                          title: 'Promotores pendientes',
                          value: leadersPending.toString(),
                          color: const Color(0xFFF97316),
                          icon: Icons.hourglass_top_rounded,
                        ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Promotores pendientes',
                          value: promotersPending.toString(),
                          color: const Color(0xFFEA580C),
                          icon: Icons.person_search_rounded,
                        ),
                      DashboardCard(
                        title: 'Guardianes rechazados',
                        value: guardiansRejected.toString(),
                        color: const Color(0xFFDC2626),
                        icon: Icons.gpp_bad_rounded,
                      ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Lideres rechazados',
                          value: leadersRejected.toString(),
                          color: const Color(0xFFBE123C),
                          icon: Icons.block_rounded,
                        ),
                      if (_sessionRole == 'leader_parent')
                        DashboardCard(
                          title: 'Promotores rechazados',
                          value: leadersRejected.toString(),
                          color: const Color(0xFFBE123C),
                          icon: Icons.block_rounded,
                        ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Promotores rechazados',
                          value: promotersRejected.toString(),
                          color: const Color(0xFF9F1239),
                          icon: Icons.person_off_rounded,
                        ),
                      if (_isPrivilegedAdmin(_sessionRole))
                        DashboardCard(
                          title: 'Grupos de WhatsApp',
                          value: whatsappGroupsRegistered.toString(),
                          color: const Color(0xFF22C55E),
                          icon: Icons.forum_rounded,
                          onTap: () => Navigator.pushNamed(
                            context,
                            AppRoutes.whatsappGroups,
                          ),
                        ),
                    ],
                  ),
                  if (_sessionRole == 'promoter') ...[
                    const SizedBox(height: 18),
                    Text(
                      'Como promotor solo puedes registrar guardianes y consultar tus propios registros.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
