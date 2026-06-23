import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/routes.dart';
import '../../data/local/db_api.dart';
import '../../data/local/local_db.dart';
import '../../data/remote/api_service.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../services/network_status_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';

class LeaderFormScreen extends StatefulWidget {
  const LeaderFormScreen({super.key});

  @override
  State<LeaderFormScreen> createState() => _LeaderFormScreenState();
}

class _LeaderFormScreenState extends State<LeaderFormScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _fullName = TextEditingController();
  final _phone = TextEditingController();

  bool _saving = false;
  bool _loadingAccess = true;
  String _sessionRole = 'unknown';

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  String _buildErrorMessage(Object error) {
    final raw = error.toString().trim();
    if (raw.isEmpty) {
      return 'error inesperado';
    }
    if (raw.length > 180) {
      return raw.substring(0, 180);
    }
    return raw;
  }

  bool _looksLikeNetworkIssue(String message) {
    final lower = message.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('connection') ||
        lower.contains('network') ||
        lower.contains('timeout') ||
        lower.contains('reintento') ||
        lower.contains('pendiente por reintento');
  }

  String _buildSyncDialogMessage({
    required int syncStatus,
    required String syncMessage,
  }) {
    if (syncStatus == 1) {
      return 'Se guardo correctamente.';
    }
    if (syncStatus == 2) {
      return syncMessage.isEmpty
          ? 'No se pudo guardar en la base porque el servidor rechazo el registro.'
          : 'No se pudo guardar en la base porque el servidor respondio:\n\n$syncMessage';
    }
    if (_looksLikeNetworkIssue(syncMessage)) {
      return 'Se guardo localmente. Se sincronizara automaticamente cuando vuelva la conexion.';
    }
    return syncMessage.isEmpty
        ? 'Se guardo localmente. Se sincronizara automaticamente cuando haya conexion.'
        : 'Se guardo localmente.\n\nDetalle:\n$syncMessage';
  }

  Future<bool> _existsInLocalDb({
    required String email,
    required String phone,
  }) async {
    final db = await LocalDb.instance.database;

    final rows = await db.query(
      'leader_records',
      where: 'LOWER(email) = ? OR phone = ?',
      whereArgs: [email.trim().toLowerCase(), phone.trim()],
      limit: 1,
    );

    return rows.isNotEmpty;
  }

  Future<bool> _existsPendingInLocalDb({
    required String email,
    required String phone,
  }) async {
    final db = await LocalDb.instance.database;

    final rows = await db.query(
      'leader_records',
      where: 'sync_status IN (?, ?)',
      whereArgs: [0, 3],
    );

    final normalizedEmail = email.trim().toLowerCase();
    final normalizedPhone = phone.trim();

    return rows.any((row) {
      final rowEmail = (row['email'] ?? '').toString().trim().toLowerCase();
      final rowPhone = (row['phone'] ?? '').toString().trim();
      return rowEmail == normalizedEmail || rowPhone == normalizedPhone;
    });
  }

  Future<void> _clearSyncedLocalDuplicates({
    required String email,
    required String phone,
  }) async {
    final db = await LocalDb.instance.database;

    await db.delete(
      'leader_records',
      where: 'sync_status = ? AND (LOWER(email) = ? OR phone = ?)',
      whereArgs: [1, email.trim().toLowerCase(), phone.trim()],
    );
  }

  Future<bool> _hasInternet() async {
    return NetworkStatusService().hasInternet();
  }

  Future<bool> _existsInRemote({
    required String email,
    required String phone,
  }) async {
    return ApiService().leaderExists(email: email, phone: phone);
  }

  Future<Map<String, dynamic>?> _resolveCurrentLeaderContext({
    required bool hasInternet,
  }) async {
    final currentUid = AuthService().currentUser?.uid ?? '';
    if (currentUid.isEmpty) return null;

    final db = await LocalDb.instance.database;
    final localRows = await db.query(
      'leader_records',
      where: 'auth_user_id = ?',
      whereArgs: [currentUid],
      limit: 1,
    );

    if (localRows.isNotEmpty) {
      return localRows.first;
    }

    if (!hasInternet) {
      return null;
    }

    final remoteProfile = await ApiService().fetchCurrentLeaderProfile();
    if (remoteProfile == null) {
      return null;
    }

    await db.insert(
      'leader_records',
      remoteProfile,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    return remoteProfile;
  }

  Future<void> _loadAccessContext() async {
    try {
      final hasInternet = await _hasInternet();
      final currentLeaderContext = await _resolveCurrentLeaderContext(
        hasInternet: hasInternet,
      );
      final adminRole =
          hasInternet ? await ApiService().fetchCurrentAdminRole() : '';

      if (!mounted) return;

      setState(() {
        if (adminRole.isNotEmpty) {
          _sessionRole = adminRole;
        } else {
          _sessionRole =
              (currentLeaderContext?['leader_role'] ?? 'unknown').toString();
        }
        _loadingAccess = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sessionRole = 'unknown';
        _loadingAccess = false;
      });
    }
  }

  String get _targetRole {
    if (_sessionRole == 'superadmin' || _sessionRole == 'admin') {
      return 'leader_parent';
    }
    if (_sessionRole == 'leader_parent') return 'promoter';
    return '';
  }

  String get _screenTitle {
    if (_targetRole == 'leader_parent') {
      return 'Registro de Lider';
    }
    if (_targetRole == 'promoter') {
      return 'Registro de Promotor';
    }
    return 'Registro';
  }

  String get _submitLabel {
    if (_targetRole == 'leader_parent') {
      return 'Registrar Lider';
    }
    if (_targetRole == 'promoter') {
      return 'Registrar Promotor';
    }
    return 'Registrar';
  }

  String? _validateLeaderRelationship({
    required Map<String, dynamic> row,
    required bool isAdminSession,
  }) {
    final localId = (row['local_id'] ?? '').toString().trim();
    final role = (row['leader_role'] ?? '').toString().trim();
    final parentLocalId =
        (row['parent_leader_local_id'] ?? '').toString().trim();
    final parentAuthUserId =
        (row['parent_leader_auth_user_id'] ?? '').toString().trim();
    final rootLocalId = (row['root_leader_local_id'] ?? '').toString().trim();
    final rootRemoteId = (row['root_leader_remote_id'] ?? '').toString().trim();
    final rootAuthUserId =
        (row['root_leader_auth_user_id'] ?? '').toString().trim();
    final rootLeaderName = (row['root_leader_name'] ?? '').toString().trim();
    final hierarchyLevel =
        int.tryParse((row['hierarchy_level'] ?? '0').toString()) ?? 0;

    if (localId.isEmpty) {
      return 'No se pudo generar el identificador del registro';
    }

    if (isAdminSession && role != 'leader_parent') {
      return 'Solo el admin puede registrar lideres';
    }

    if (!isAdminSession && role != 'promoter') {
      return 'Solo un lider puede registrar promotores';
    }

    if (role == 'leader_parent') {
      if (parentLocalId.isNotEmpty || parentAuthUserId.isNotEmpty) {
        return 'El lider no debe guardar un padre asignado';
      }
      if (rootLocalId.isEmpty || rootRemoteId.isEmpty) {
        return 'El lider debe quedar ligado a si mismo como raiz';
      }
      if (hierarchyLevel != 1) {
        return 'El nivel jerarquico del lider debe ser 1';
      }
      return null;
    }

    if (parentLocalId.isEmpty || parentAuthUserId.isEmpty) {
      return 'El promotor debe quedar ligado al lider que lo registro';
    }
    if (rootLocalId.isEmpty ||
        rootRemoteId.isEmpty ||
        rootAuthUserId.isEmpty ||
        rootLeaderName.isEmpty) {
      return 'El promotor debe quedar ligado al lider raiz';
    }
    if (parentLocalId == localId) {
      return 'El promotor no puede apuntarse a si mismo como padre';
    }
    if (hierarchyLevel < 2) {
      return 'El nivel jerarquico del promotor debe ser mayor a 1';
    }

    return null;
  }

  Future<void> _save() async {
    final email = _email.text.trim().toLowerCase();
    final phone = _phone.text.trim();
    final password = _password.text.trim();

    if (email.isEmpty ||
        phone.isEmpty ||
        _fullName.text.trim().isEmpty ||
        password.isEmpty) {
      _showSnack('Completa correo, contrasena, nombre y telefono');
      return;
    }

    if (password.length < 6) {
      _showSnack('La contrasena debe tener al menos 6 caracteres');
      return;
    }

    setState(() => _saving = true);

    try {
      final hasInternet = await _hasInternet();

      if (hasInternet) {
        final existsRemote = await _existsInRemote(email: email, phone: phone);
        if (existsRemote) {
          _showSnack('Este ya se encuentra registrado');
          return;
        }

        final authExists = await AuthService().leaderAccessExists(email);
        if (authExists) {
          _showSnack('El correo ya tiene un acceso creado');
          return;
        }

        await _clearSyncedLocalDuplicates(email: email, phone: phone);

        final existsPendingLocal = await _existsPendingInLocalDb(
          email: email,
          phone: phone,
        );
        if (existsPendingLocal) {
          _showSnack('Este ya se encuentra registrado');
          return;
        }
      } else {
        final existsLocal = await _existsInLocalDb(email: email, phone: phone);
        if (existsLocal) {
          _showSnack('Este ya se encuentra registrado');
          return;
        }
      }

      final currentUser = AuthService().currentUser;
      if (currentUser == null) {
        _showSnack('Tu sesion no esta activa. Vuelve a iniciar sesion.');
        return;
      }

      final uid = currentUser.uid;
      final registeredByEmail = currentUser.email.toLowerCase();
      final registeredByName = currentUser.displayName;
      final currentLeaderContext = await _resolveCurrentLeaderContext(
        hasInternet: hasInternet,
      );
      final isAdminSession =
          hasInternet ? await ApiService().isCurrentUserAdmin() : false;
      final db = await LocalDb.instance.database;
      final localId = const Uuid().v4();
      final currentLeaderRole =
          (currentLeaderContext?['leader_role'] ?? '').toString().trim();
      final isLeaderParentSession = currentLeaderRole == 'leader_parent';
      final isPromoterSession = currentLeaderRole == 'promoter';

      if (!isAdminSession && !isLeaderParentSession) {
        _showSnack(
          'Solo el admin puede crear lideres y solo un lider puede crear promotores.',
        );
        return;
      }

      if (isPromoterSession) {
        _showSnack(
          'Los promotores no pueden registrar nuevos promotores ni lideres.',
        );
        return;
      }

      final targetRole = isAdminSession ? 'leader_parent' : 'promoter';
      final currentLeaderName =
          (currentLeaderContext?['full_name'] ?? '').toString().trim();
      final currentLeaderRemoteId =
          (currentLeaderContext?['remote_id'] ?? '').toString().trim();
      final currentLeaderAuthUserId =
          (currentLeaderContext?['auth_user_id'] ?? '').toString().trim();
      final currentHierarchyLevel = int.tryParse(
            (currentLeaderContext?['hierarchy_level'] ?? '1').toString(),
          ) ??
          1;
      final inheritedRootLocalId =
          (currentLeaderContext?['root_leader_local_id'] ?? '')
              .toString()
              .trim();
      final inheritedRootRemoteId =
          (currentLeaderContext?['root_leader_remote_id'] ?? '')
              .toString()
              .trim();
      final inheritedRootAuthUserId =
          (currentLeaderContext?['root_leader_auth_user_id'] ?? '')
              .toString()
              .trim();
      final inheritedRootName =
          (currentLeaderContext?['root_leader_name'] ?? '').toString().trim();
      final currentLeaderLocalId =
          (currentLeaderContext?['local_id'] ?? '').toString().trim();
      final ownerAdminUserId = isAdminSession
          ? uid
          : (currentLeaderContext?['owner_admin_user_id'] ?? '')
              .toString()
              .trim();
      final ownerAdminName = isAdminSession
          ? currentUser.displayName
          : (currentLeaderContext?['owner_admin_name'] ?? '')
              .toString()
              .trim();
      final ownerAdminEmail = isAdminSession
          ? registeredByEmail
          : (currentLeaderContext?['owner_admin_email'] ?? '')
              .toString()
              .trim();
      final resolvedParentLeaderRemoteId = currentLeaderRemoteId.isEmpty
          ? (currentLeaderLocalId.isEmpty ? null : currentLeaderLocalId)
          : currentLeaderRemoteId;
      final resolvedRootLeaderLocalId = isLeaderParentSession
          ? (inheritedRootLocalId.isEmpty
              ? (currentLeaderLocalId.isEmpty ? null : currentLeaderLocalId)
              : inheritedRootLocalId)
          : localId;
      final resolvedRootLeaderRemoteId = isLeaderParentSession
          ? (inheritedRootRemoteId.isEmpty
              ? resolvedParentLeaderRemoteId
              : inheritedRootRemoteId)
          : localId;
      final resolvedRootLeaderAuthUserId = isLeaderParentSession
          ? (inheritedRootAuthUserId.isEmpty
              ? (currentLeaderAuthUserId.isEmpty
                  ? null
                  : currentLeaderAuthUserId)
              : inheritedRootAuthUserId)
          : null;
      final resolvedRootLeaderName = isLeaderParentSession
          ? (inheritedRootName.isEmpty
              ? (currentLeaderName.isEmpty ? null : currentLeaderName)
              : inheritedRootName)
          : _fullName.text.trim();

      final leaderRow = <String, dynamic>{
        'local_id': localId,
        'remote_id': null,
        'capturist_id': uid,
        'registered_by_user_id': uid,
        'registered_by_user_email': registeredByEmail,
        'registered_by_user_name': registeredByName,
        'owner_admin_user_id': ownerAdminUserId.isEmpty ? null : ownerAdminUserId,
        'owner_admin_name': ownerAdminName.isEmpty ? null : ownerAdminName,
        'owner_admin_email': ownerAdminEmail.isEmpty ? null : ownerAdminEmail,
        'auth_user_id': null,
        'leader_role': targetRole,
        'parent_leader_local_id':
            isLeaderParentSession ? currentLeaderContext!['local_id'] : null,
        'parent_leader_remote_id':
            isLeaderParentSession ? resolvedParentLeaderRemoteId : null,
        'parent_leader_auth_user_id': isLeaderParentSession
            ? (currentLeaderAuthUserId.isEmpty ? null : currentLeaderAuthUserId)
            : null,
        'parent_leader_name': isLeaderParentSession
            ? (currentLeaderName.isEmpty ? null : currentLeaderName)
            : null,
        'root_leader_local_id': resolvedRootLeaderLocalId,
        'root_leader_remote_id': resolvedRootLeaderRemoteId,
        'root_leader_auth_user_id': resolvedRootLeaderAuthUserId,
        'root_leader_name': resolvedRootLeaderName,
        'hierarchy_level':
            isLeaderParentSession ? currentHierarchyLevel + 1 : 1,
        'email': email,
        'password': password,
        'full_name': _fullName.text.trim(),
        'phone': phone,
        'sync_status': 0,
        'created_at': DateTime.now().toIso8601String(),
      };

      final relationshipError = _validateLeaderRelationship(
        row: leaderRow,
        isAdminSession: isAdminSession,
      );
      if (relationshipError != null) {
        _showSnack(relationshipError);
        return;
      }

      await db.insert(
        'leader_records',
        {
          ...leaderRow,
          'sync_message': 'Pendiente de sincronizacion',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await SyncService().syncPendingLeaders();

      final savedRows = await db.query(
        'leader_records',
        where: 'LOWER(email) = ? AND phone = ?',
        whereArgs: [email, phone],
        orderBy: 'created_at DESC',
        limit: 1,
      );

      final savedLeader = savedRows.isNotEmpty ? savedRows.first : null;
      final syncStatus = savedLeader?['sync_status'] as int? ?? 0;
      final syncMessage =
          (savedLeader?['sync_message'] ?? '').toString().trim();

      AppDataBus.notify();
      if (!mounted) return;

      final title = syncStatus == 1
          ? 'Se guardo correctamente'
          : syncStatus == 2
              ? 'Registro rechazado'
              : 'Se guardo localmente';
      final message = _buildSyncDialogMessage(
        syncStatus: syncStatus,
        syncMessage: syncMessage,
      );

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  AppRoutes.dashboard,
                  (route) => false,
                );
              },
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    } catch (error) {
      _showSnack(
          'No se pudo guardar el registro: ${_buildErrorMessage(error)}');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadAccessContext();
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _fullName.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        title: Text(
          _screenTitle,
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: _loadingAccess
          ? const Center(child: CircularProgressIndicator())
          : (_targetRole.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Tu rol actual no tiene permiso para registrar lideres o promotores.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      AppTextField(
                        controller: _email,
                        label: 'Correo Electronico',
                        icon: Icons.alternate_email,
                      ),
                      const SizedBox(height: 16),
                      AppTextField(
                        controller: _password,
                        label: 'Contrasena',
                        icon: Icons.password,
                        obscureText: true,
                      ),
                      const SizedBox(height: 16),
                      AppTextField(
                        controller: _fullName,
                        label: 'Nombre completo',
                        icon: Icons.people,
                      ),
                      const SizedBox(height: 16),
                      AppTextField(
                        controller: _phone,
                        label: 'Telefono',
                        icon: Icons.phone,
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 26),
                      PrimaryButton(
                        text: _saving ? 'Guardando...' : _submitLabel,
                        onPressed: _saving ? null : _save,
                      ),
                    ],
                  ),
                )),
    );
  }
}
