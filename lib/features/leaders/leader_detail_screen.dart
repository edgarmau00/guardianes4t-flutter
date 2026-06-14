import 'package:flutter/material.dart';
import '../../data/local/local_db.dart';
import '../../services/app_data_bus.dart';
import '../../services/auth_service.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';

class LeaderDetailScreen extends StatefulWidget {
  const LeaderDetailScreen({super.key});

  @override
  State<LeaderDetailScreen> createState() => _LeaderDetailScreenState();
}

class _LeaderDetailScreenState extends State<LeaderDetailScreen> {
  late Map<String, dynamic> _leader;
  bool _isAdmin = false;
  bool _checkingRole = true;
  bool _updatingAccess = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
    _leader = Map<String, dynamic>.from(args);
    _loadAccessRole();
  }

  Future<void> _loadAccessRole() async {
    if (!_checkingRole) return;

    final role = AuthService().currentUser?.role ?? '';
    final isAdmin = role == 'admin' || role == 'superadmin';
    if (!mounted) return;

    setState(() {
      _isAdmin = isAdmin;
      _checkingRole = false;
    });
  }

  Future<void> _openEditAccessDialog() async {
    final emailController = TextEditingController(
      text: (_leader['email'] ?? '').toString(),
    );
    final passwordController = TextEditingController(
      text: (_leader['password'] ?? '').toString(),
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Editar acceso'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextField(
                  controller: emailController,
                  label: 'Correo',
                  icon: Icons.alternate_email_rounded,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                AppTextField(
                  controller: passwordController,
                  label: 'Contrasena',
                  icon: Icons.lock_outline_rounded,
                  obscureText: true,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Guardar'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    await _saveAccessChanges(
      newEmail: emailController.text,
      newPassword: passwordController.text,
    );
  }

  Future<void> _saveAccessChanges({
    required String newEmail,
    required String newPassword,
  }) async {
    final cleanNewEmail = newEmail.trim().toLowerCase();
    final cleanNewPassword = newPassword.trim();

    if (cleanNewEmail.isEmpty || cleanNewPassword.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Correo y contrasena son obligatorios'),
        ),
      );
      return;
    }

    if (cleanNewPassword.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La contrasena debe tener al menos 6 caracteres'),
        ),
      );
      return;
    }

    setState(() => _updatingAccess = true);

    try {
      await AuthService().updateLeaderAccess(
        leaderId:
            (_leader['remote_id'] ?? _leader['local_id'] ?? '').toString(),
        newEmail: cleanNewEmail,
        newPassword: cleanNewPassword,
      );

      final db = await LocalDb.instance.database;
      await db.update(
        'leader_records',
        {
          'email': cleanNewEmail,
          'password': cleanNewPassword,
          'sync_status': 1,
          'sync_message': 'Sincronizado correctamente',
        },
        where: 'local_id = ?',
        whereArgs: [_leader['local_id']],
      );

      final refreshedRows = await db.query(
        'leader_records',
        where: 'local_id = ?',
        whereArgs: [_leader['local_id']],
        limit: 1,
      );

      if (refreshedRows.isNotEmpty && mounted) {
        setState(() {
          _leader = Map<String, dynamic>.from(refreshedRows.first);
        });
      }

      AppDataBus.notify();

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Acceso actualizado correctamente'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo actualizar el acceso. Intenta de nuevo.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _updatingAccess = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);
    final canEditAccess = _isAdmin;
    final hasRemoteAccess =
        (_leader['remote_id'] ?? '').toString().trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Detalle de lider',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (_leader['full_name'] ?? '').toString().toUpperCase(),
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 18),
              _DetailRow(
                label: 'Correo',
                value: (_leader['email'] ?? '').toString(),
              ),
              const SizedBox(height: 12),
              _DetailRow(
                label: 'Contrasena actual',
                value: (_leader['password'] ?? '').toString().trim().isEmpty
                    ? 'No disponible'
                    : 'Disponible para editar',
              ),
              if (canEditAccess) ...[
                const SizedBox(height: 24),
                PrimaryButton(
                  text: _updatingAccess
                      ? 'Actualizando acceso...'
                      : 'Editar correo y contrasena',
                  icon: Icons.edit_rounded,
                  onPressed: (_updatingAccess || !hasRemoteAccess)
                      ? null
                      : _openEditAccessDialog,
                ),
                if (!hasRemoteAccess) ...[
                  const SizedBox(height: 10),
                  const Text(
                    'Sincroniza este registro antes de modificar su acceso.',
                    style: TextStyle(
                      color: Color(0xFF7A0C0C),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            color: Colors.black54,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 18,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}
