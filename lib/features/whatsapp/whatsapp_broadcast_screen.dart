import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../widgets/primary_button.dart';

class WhatsappBroadcastScreen extends StatefulWidget {
  const WhatsappBroadcastScreen({super.key});

  @override
  State<WhatsappBroadcastScreen> createState() =>
      _WhatsappBroadcastScreenState();
}

class _WhatsappBroadcastScreenState extends State<WhatsappBroadcastScreen> {
  final _message = TextEditingController();
  List<Map<String, dynamic>> _groups = [];
  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args =
        (ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?) ??
            {};
    final rawGroups = (args['groups'] as List<dynamic>? ?? const []);
    _groups = rawGroups
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  Future<void> _copyMessage() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Escribe un mensaje primero'),
        ),
      );
      return;
    }

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Mensaje copiado al portapapeles'),
      ),
    );
  }

  Future<void> _openGroups() async {
    if (_groups.isEmpty) {
      return;
    }

    setState(() => _opening = true);

    try {
      for (final group in _groups) {
        final inviteLink = (group['invite_link'] ?? '').toString().trim();
        if (inviteLink.isEmpty) continue;

        final uri = Uri.tryParse(inviteLink);
        if (uri == null) continue;

        await launchUrl(uri, mode: LaunchMode.externalApplication);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF7A0C0C);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Enviar mensaje',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Grupos seleccionados',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_groups.isEmpty)
                    const Text(
                      'No seleccionaste grupos.',
                      style: TextStyle(color: Color(0xFF6B7280)),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _groups.map((group) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7A0C0C).withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            (group['name'] ?? '').toString(),
                            style: const TextStyle(
                              color: Color(0xFF7A0C0C),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Mensaje',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _message,
                    minLines: 6,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      hintText: 'Escribe aqui el mensaje que vas a compartir',
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Tip: copia primero el mensaje y despues abre los grupos para pegarlo rapidamente en WhatsApp.',
                    style: TextStyle(
                      color: Color(0xFF6B7280),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            PrimaryButton(
              text: 'Copiar mensaje',
              icon: Icons.copy_rounded,
              onPressed: _copyMessage,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _opening ? null : _openGroups,
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(
                  _opening ? 'Abriendo grupos...' : 'Abrir grupos seleccionados',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
