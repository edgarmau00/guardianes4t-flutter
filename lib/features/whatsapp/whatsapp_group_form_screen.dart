import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/db_api.dart';
import '../../data/local/local_db.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../services/sync_service.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';

class WhatsappGroupFormScreen extends StatefulWidget {
  const WhatsappGroupFormScreen({super.key});

  @override
  State<WhatsappGroupFormScreen> createState() =>
      _WhatsappGroupFormScreenState();
}

class _WhatsappGroupFormScreenState extends State<WhatsappGroupFormScreen> {
  final _name = TextEditingController();
  final _inviteLink = TextEditingController();
  final _notes = TextEditingController();

  bool _active = true;
  bool _saving = false;
  String? _editingId;
  String? _editingRemoteId;
  bool _loadedArgs = false;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedArgs) return;

    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    if (args != null) {
      _editingId = (args['local_id'] ?? '').toString().trim();
      _editingRemoteId = (args['remote_id'] ?? '').toString().trim();
      _name.text = (args['name'] ?? '').toString();
      _inviteLink.text = (args['invite_link'] ?? '').toString();
      _notes.text = (args['notes'] ?? '').toString();
      _active = (args['active'] ?? 1) == 1;
    }

    _loadedArgs = true;
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final inviteLink = _inviteLink.text.trim();
    final notes = _notes.text.trim();

    if (name.isEmpty || inviteLink.isEmpty) {
      _showSnack('Nombre y enlace del grupo son obligatorios');
      return;
    }

    setState(() => _saving = true);

    try {
      final db = await LocalDb.instance.database;
      final currentUser = AuthService().currentUser;
      final uid = currentUser?.uid ?? '';
      final email = currentUser?.email.toLowerCase() ?? '';
      final localId =
          _editingId?.isNotEmpty == true ? _editingId! : const Uuid().v4();

      await db.insert(
        'whatsapp_groups',
        {
          'local_id': localId,
          'remote_id':
              _editingRemoteId?.isNotEmpty == true ? _editingRemoteId : null,
          'name': name,
          'invite_link': inviteLink,
          'notes': notes,
          'active': _active ? 1 : 0,
          'created_by_user_id': uid,
          'created_by_user_email': email,
          'sync_status': 0,
          'sync_message': 'Pendiente de sincronizacion',
          'created_at': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await SyncService().syncPendingWhatsappGroups();
      final savedRows = await db.query(
        'whatsapp_groups',
        where: 'local_id = ? OR remote_id = ?',
        whereArgs: [localId, localId],
        limit: 1,
      );
      final savedGroup = savedRows.isNotEmpty ? savedRows.first : null;
      final syncStatus = savedGroup?['sync_status'] as int? ?? 0;
      final syncMessage = (savedGroup?['sync_message'] ?? '').toString().trim();
      AppDataBus.notify();

      if (!mounted) return;
      final title = syncStatus == 1
          ? 'Se guardo correctamente'
          : syncStatus == 2
              ? 'Registro rechazado'
              : 'Se guardo localmente';
      final message = syncStatus == 1
          ? 'Se guardo correctamente.'
          : syncStatus == 2
              ? (syncMessage.isEmpty
                  ? 'No se pudo guardar en la base porque el servidor rechazo el registro.'
                  : 'No se pudo guardar en la base porque el servidor respondio:\n\n$syncMessage')
              : _looksLikeNetworkIssue(syncMessage)
                  ? 'Se guardo localmente. Se sincronizara automaticamente cuando vuelva la conexion.'
                  : 'Se guardo localmente. Se sincronizara automaticamente cuando haya conexion.';

      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _inviteLink.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);
    final isEditing = _editingId?.isNotEmpty == true;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(
          isEditing ? 'Editar grupo de WhatsApp' : 'Nuevo grupo de WhatsApp',
          style: const TextStyle(color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(18),
        child: Column(
          children: [
            AppTextField(
              controller: _name,
              label: 'Nombre del grupo',
              icon: Icons.group_rounded,
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _inviteLink,
              label: 'Enlace de invitacion',
              icon: Icons.link_rounded,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 14),
            AppTextField(
              controller: _notes,
              label: 'Notas',
              icon: Icons.notes_rounded,
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              value: _active,
              activeThumbColor: primary,
              contentPadding: EdgeInsets.zero,
              title: const Text('Grupo activo'),
              subtitle:
                  const Text('Solo los activos apareceran como disponibles'),
              onChanged: (value) => setState(() => _active = value),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              text: _saving ? 'Guardando...' : 'Guardar grupo',
              icon: Icons.save_rounded,
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
