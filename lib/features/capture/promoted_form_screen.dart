import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/routes.dart';
import '../../data/local/db_api.dart';
import '../../data/local/local_db.dart';
import '../../data/models/promoted_record.dart';
import '../../data/remote/api_service.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../services/cp_service.dart';
import '../../services/network_status_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';

class PromotedFormScreen extends StatefulWidget {
  const PromotedFormScreen({super.key});

  @override
  State<PromotedFormScreen> createState() => _PromotedFormScreenState();
}

class _PromotedFormScreenState extends State<PromotedFormScreen> {
  final _claveElectoral = TextEditingController();
  final _sexo = TextEditingController();
  final _nombre = TextEditingController();
  final _apellidoPaterno = TextEditingController();
  final _apellidoMaterno = TextEditingController();
  final _direccion = TextEditingController();
  final _codigoPostal = TextEditingController();
  final _vigencia = TextEditingController();
  final _seccion = TextEditingController();
  final _fechaNacimiento = TextEditingController();
  final _curp = TextEditingController();
  final _estado = TextEditingController();
  final _municipio = TextEditingController();
  final _whatsapp = TextEditingController();

  bool _discapacidad = false;
  String? _imagePath;
  bool _loadedArgs = false;
  bool _saving = false;

  String _cleanCp(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedArgs) return;

    _resetForm();

    final args =
        (ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?) ??
            {};

    _imagePath = args['imagePath'] as String?;
    _claveElectoral.text =
        (args['claveElectoral'] ?? args['claveElector'] ?? '').toString();
    _sexo.text = (args['sexo'] ?? '').toString();
    _nombre.text = (args['nombre'] ?? '').toString();
    _apellidoPaterno.text = (args['apellidoPaterno'] ?? '').toString();
    _apellidoMaterno.text = (args['apellidoMaterno'] ?? '').toString();
    _direccion.text = (args['direccion'] ?? '').toString();
    _codigoPostal.text = _cleanCp((args['codigoPostal'] ?? '').toString());
    _vigencia.text = (args['vigencia'] ?? '').toString();
    _seccion.text =
        (args['seccionElectoral'] ?? args['seccion'] ?? '').toString();
    _fechaNacimiento.text = (args['fechaNacimiento'] ?? '').toString();
    _curp.text = (args['curp'] ?? '').toString();

    final cp = _cleanCp(_codigoPostal.text);
    if (cp.length == 5) {
      _codigoPostal.text = cp;
      _fillStateAndMunicipioFromCp(cp);
    } else {
      _estado.text = (args['estado'] ?? '').toString();
      _municipio.text = (args['municipio'] ?? '').toString();
    }

    _loadedArgs = true;
  }

  void _resetForm() {
    _imagePath = null;
    _claveElectoral.clear();
    _sexo.clear();
    _nombre.clear();
    _apellidoPaterno.clear();
    _apellidoMaterno.clear();
    _direccion.clear();
    _codigoPostal.clear();
    _vigencia.clear();
    _seccion.clear();
    _fechaNacimiento.clear();
    _curp.clear();
    _estado.clear();
    _municipio.clear();
    _whatsapp.clear();
    _discapacidad = false;
  }

  void _fillStateAndMunicipioFromCp(String cp) {
    final cleanCp = _cleanCp(cp);

    if (cleanCp.length != 5) {
      setState(() {
        _estado.clear();
        _municipio.clear();
      });
      return;
    }

    final data = CpService.getDataByCp(cleanCp);

    if (data == null) {
      setState(() {
        _estado.clear();
        _municipio.clear();
      });
      return;
    }

    setState(() {
      _estado.text = (data['estado'] ?? '').toString();
      _municipio.text = (data['municipio'] ?? '').toString();
    });
  }

  Future<bool> _existsInLocalDb(String claveElectoral) async {
    final db = await LocalDb.instance.database;

    final rows = await db.query(
      'promoted_records',
      where: 'UPPER(clave_electoral) = ?',
      whereArgs: [claveElectoral.trim().toUpperCase()],
      limit: 1,
    );

    return rows.isNotEmpty;
  }

  Future<bool> _existsPendingInLocalDb(String claveElectoral) async {
    final db = await LocalDb.instance.database;

    final rows = await db.query(
      'promoted_records',
      where: 'sync_status IN (?, ?)',
      whereArgs: [0, 3],
    );

    final normalizedClave = claveElectoral.trim().toUpperCase();

    return rows.any((row) {
      final rowClave =
          (row['clave_electoral'] ?? '').toString().trim().toUpperCase();
      return rowClave == normalizedClave;
    });
  }

  Future<void> _clearSyncedLocalDuplicate(String claveElectoral) async {
    final db = await LocalDb.instance.database;

    await db.delete(
      'promoted_records',
      where: 'sync_status = ? AND UPPER(clave_electoral) = ?',
      whereArgs: [1, claveElectoral.trim().toUpperCase()],
    );
  }

  Future<bool> _hasInternet() async {
    return NetworkStatusService().hasInternet();
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

  Future<void> _save() async {
    final clave = _claveElectoral.text.trim().toUpperCase();
    final cp = _cleanCp(_codigoPostal.text);
    final currentUser = AuthService().currentUser;

    if (clave.isEmpty) {
      _showSnack('La clave de elector es obligatoria');
      return;
    }

    if (cp.isNotEmpty && cp.length != 5) {
      _showSnack('El codigo postal debe tener 5 digitos');
      return;
    }

    if (currentUser == null) {
      _showSnack('Tu sesion no esta activa. Vuelve a iniciar sesion.');
      return;
    }

    if (cp.length == 5) {
      _codigoPostal.text = cp;
      _fillStateAndMunicipioFromCp(cp);
    }

    setState(() => _saving = true);

    try {
      final hasInternet = await _hasInternet();

      if (hasInternet) {
        final existsRemote =
            await ApiService().promotedExistsByClaveElectoral(clave);
        if (existsRemote) {
          _showSnack('Este ya se encuentra registrado');
          return;
        }

        await _clearSyncedLocalDuplicate(clave);

        final existsPendingLocal = await _existsPendingInLocalDb(clave);
        if (existsPendingLocal) {
          _showSnack('Este ya se encuentra registrado');
          return;
        }
      } else {
        final existsLocal = await _existsInLocalDb(clave);
        if (existsLocal) {
          _showSnack('Este ya se encuentra registrado');
          return;
        }
      }

      final uid = currentUser.uid;
      final registeredByEmail = currentUser.email.toLowerCase();
      final currentLeaderContext = await _resolveCurrentLeaderContext(
        hasInternet: hasInternet,
      );
      final currentLeaderRole =
          (currentLeaderContext?['leader_role'] ?? '').toString().trim();
      final currentLeaderName =
          (currentLeaderContext?['full_name'] ?? '').toString().trim();
      final currentLeaderLocalId =
          (currentLeaderContext?['local_id'] ?? '').toString().trim();
      final currentLeaderRemoteId =
          (currentLeaderContext?['remote_id'] ?? '').toString().trim();
      final currentLeaderAuthUserId =
          (currentLeaderContext?['auth_user_id'] ?? '').toString().trim();
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
      final ownerAdminUserId =
          (currentLeaderContext?['owner_admin_user_id'] ?? uid).toString().trim();
      final ownerAdminName =
          (currentLeaderContext?['owner_admin_name'] ?? '').toString().trim();
      final ownerAdminEmail =
          (currentLeaderContext?['owner_admin_email'] ?? registeredByEmail)
              .toString()
              .trim();
      final id = const Uuid().v4();

      final ownerLeaderLocalId = currentLeaderRole == 'promoter'
          ? (inheritedRootLocalId.isEmpty ? null : inheritedRootLocalId)
          : (currentLeaderRole == 'leader_parent'
              ? (currentLeaderLocalId.isEmpty ? null : currentLeaderLocalId)
              : null);
      final ownerLeaderRemoteId = currentLeaderRole == 'promoter'
          ? (inheritedRootRemoteId.isEmpty ? null : inheritedRootRemoteId)
          : (currentLeaderRole == 'leader_parent'
              ? (currentLeaderRemoteId.isEmpty ? null : currentLeaderRemoteId)
              : null);
      final ownerLeaderAuthUserId = currentLeaderRole == 'promoter'
          ? (inheritedRootAuthUserId.isEmpty ? null : inheritedRootAuthUserId)
          : (currentLeaderRole == 'leader_parent'
              ? (currentLeaderAuthUserId.isEmpty
                  ? null
                  : currentLeaderAuthUserId)
              : null);
      final ownerLeaderName = currentLeaderRole == 'promoter'
          ? (inheritedRootName.isEmpty ? null : inheritedRootName)
          : (currentLeaderRole == 'leader_parent'
              ? (currentLeaderName.isEmpty ? null : currentLeaderName)
              : null);
      final ownerPromoterUserId = currentLeaderRole == 'promoter' ? uid : null;
      final ownerPromoterName =
          currentLeaderRole == 'promoter' ? currentUser.displayName : null;

      final record = PromotedRecord(
        localId: id,
        capturistId: uid,
        registeredByUserId: uid,
        registeredByUserEmail: registeredByEmail,
        ownerAdminUserId: ownerAdminUserId.isEmpty ? null : ownerAdminUserId,
        ownerAdminName: ownerAdminName.isEmpty ? null : ownerAdminName,
        ownerAdminEmail: ownerAdminEmail.isEmpty ? null : ownerAdminEmail,
        ownerLeaderLocalId: ownerLeaderLocalId,
        ownerLeaderRemoteId: ownerLeaderRemoteId,
        ownerLeaderAuthUserId: ownerLeaderAuthUserId,
        ownerLeaderName: ownerLeaderName,
        ownerPromoterUserId: ownerPromoterUserId,
        ownerPromoterName: ownerPromoterName,
        imagePath: _imagePath,
        claveElectoral: clave,
        sexo: _sexo.text.trim(),
        nombre: _nombre.text.trim(),
        apellidoPaterno: _apellidoPaterno.text.trim(),
        apellidoMaterno: _apellidoMaterno.text.trim(),
        direccion: _direccion.text.trim(),
        codigoPostal: cp,
        vigencia: _vigencia.text.trim(),
        seccionElectoral: _seccion.text.trim(),
        fechaNacimiento: _fechaNacimiento.text.trim(),
        curp: _curp.text.trim(),
        estado: _estado.text.trim(),
        municipio: _municipio.text.trim(),
        telefono: _whatsapp.text.trim(),
        whatsapp: _whatsapp.text.trim(),
        discapacidad: _discapacidad,
        syncStatus: 0,
        createdAt: DateTime.now().toIso8601String(),
      );

      final db = await LocalDb.instance.database;
      await db.insert(
        'promoted_records',
        {
          ...record.toMap(),
          'sync_message': 'Pendiente de sincronizacion',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await SyncService().syncPendingPromoted();

      final savedRows = await db.query(
        'promoted_records',
        where: 'UPPER(clave_electoral) = ? AND capturist_id = ?',
        whereArgs: [clave, uid],
        orderBy: 'created_at DESC',
        limit: 1,
      );
      final savedRecord = savedRows.isNotEmpty ? savedRows.first : null;
      final syncStatus = savedRecord?['sync_status'] as int? ?? 0;
      final syncMessage =
          (savedRecord?['sync_message'] ?? '').toString().trim();

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
          'No se pudo guardar el guardian: ${_buildErrorMessage(error)}');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _claveElectoral.dispose();
    _sexo.dispose();
    _nombre.dispose();
    _apellidoPaterno.dispose();
    _apellidoMaterno.dispose();
    _direccion.dispose();
    _codigoPostal.dispose();
    _vigencia.dispose();
    _seccion.dispose();
    _fechaNacimiento.dispose();
    _curp.dispose();
    _estado.dispose();
    _municipio.dispose();
    _whatsapp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        title: const Text(
          'Registro de Guardian',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            AppTextField(
              controller: _claveElectoral,
              label: 'Clave de Elector',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _sexo,
              label: 'Sexo',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _nombre,
              label: 'Nombre',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _apellidoPaterno,
              label: 'Apellido Paterno',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _apellidoMaterno,
              label: 'Apellido Materno',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _direccion,
              label: 'Direccion',
              maxLines: 2,
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _codigoPostal,
              label: 'Codigo Postal',
              keyboardType: TextInputType.number,
              onChanged: (value) {
                final cp = _cleanCp(value);

                if (_codigoPostal.text != cp) {
                  _codigoPostal.value = TextEditingValue(
                    text: cp,
                    selection: TextSelection.collapsed(offset: cp.length),
                  );
                }

                if (cp.length == 5) {
                  _fillStateAndMunicipioFromCp(cp);
                } else {
                  _estado.clear();
                  _municipio.clear();
                }
              },
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _estado,
              label: 'Estado',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _municipio,
              label: 'Municipio',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _vigencia,
              label: 'Vigencia',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _seccion,
              label: 'SECCION',
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _fechaNacimiento,
              label: 'Fecha de Nacimiento',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _curp,
              label: 'CURP',
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _whatsapp,
              label: 'WhatsApp',
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Expanded(
                  child: Text(
                    'En su hogar conviven personas con discapacidades?',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
                Checkbox(
                  value: _discapacidad,
                  onChanged: (v) => setState(() => _discapacidad = v ?? false),
                ),
              ],
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              text: _saving ? 'Guardando...' : 'Registrar',
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
