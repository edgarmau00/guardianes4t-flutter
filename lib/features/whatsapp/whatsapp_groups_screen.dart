import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/routes.dart';
import '../../data/local/local_db.dart';
import '../../services/app_data_bus.dart';
import '../../services/sync_service.dart';

class WhatsappGroupsScreen extends StatefulWidget {
  const WhatsappGroupsScreen({super.key});

  @override
  State<WhatsappGroupsScreen> createState() => _WhatsappGroupsScreenState();
}

class _WhatsappGroupsScreenState extends State<WhatsappGroupsScreen> {
  StreamSubscription<int>? _busSubscription;
  final Set<String> _selectedIds = {};
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _busSubscription = AppDataBus.stream.listen((_) => _load());
  }

  Future<void> _load() async {
    try {
      await SyncService().pullWhatsappGroups();
    } catch (_) {}

    final db = await LocalDb.instance.database;
    final rows = await db.query(
      'whatsapp_groups',
      orderBy: 'created_at DESC',
    );

    if (!mounted) return;
    setState(() {
      _items = rows;
      _loading = false;
      _selectedIds.removeWhere(
        (id) => !_items.any((item) => (item['local_id'] ?? '') == id),
      );
    });
  }

  List<Map<String, dynamic>> get _selectedGroups {
    return _items
        .where((item) => _selectedIds.contains((item['local_id'] ?? '').toString()))
        .toList();
  }

  Future<void> _openBroadcastScreen() async {
    final selectedGroups = _selectedGroups;
    if (selectedGroups.isEmpty) {
      return;
    }
    await Navigator.pushNamed(
      context,
      AppRoutes.whatsappBroadcast,
      arguments: {
        'groups': selectedGroups,
      },
    );
  }

  @override
  void dispose() {
    _busSubscription?.cancel();
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
          'Grupos de WhatsApp',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          if (_selectedIds.isNotEmpty)
            IconButton(
              tooltip: 'Preparar mensaje',
              onPressed: _openBroadcastScreen,
              icon: const Icon(Icons.send_rounded),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pushNamed(context, AppRoutes.whatsappGroupForm),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuevo grupo'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? const Center(
                  child: Text('No hay grupos de WhatsApp registrados'),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 14),
                  itemBuilder: (_, index) {
                    final item = _items[index];
                    final localId = (item['local_id'] ?? '').toString();
                    final selected = _selectedIds.contains(localId);
                    final active = (item['active'] ?? 1) == 1;

                    return InkWell(
                      onTap: () {
                        setState(() {
                          if (selected) {
                            _selectedIds.remove(localId);
                          } else {
                            _selectedIds.add(localId);
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xFF7A0C0C).withValues(alpha: 0.06)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: selected
                                ? const Color(0xFF7A0C0C)
                                : const Color(0xFFE5E7EB),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: selected,
                              activeColor: primary,
                              onChanged: (_) {
                                setState(() {
                                  if (selected) {
                                    _selectedIds.remove(localId);
                                  } else {
                                    _selectedIds.add(localId);
                                  }
                                });
                              },
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          (item['name'] ?? '').toString(),
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.w800,
                                            color: Color(0xFF111827),
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: active
                                              ? const Color(0xFFDCFCE7)
                                              : const Color(0xFFF3F4F6),
                                          borderRadius:
                                              BorderRadius.circular(999),
                                        ),
                                        child: Text(
                                          active ? 'Activo' : 'Inactivo',
                                          style: TextStyle(
                                            color: active
                                                ? const Color(0xFF166534)
                                                : const Color(0xFF6B7280),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    (item['invite_link'] ?? '').toString(),
                                    style: const TextStyle(
                                      color: Color(0xFF6B7280),
                                      fontSize: 14,
                                    ),
                                  ),
                                  if ((item['notes'] ?? '').toString().trim().isNotEmpty) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      (item['notes'] ?? '').toString(),
                                      style: const TextStyle(
                                        color: Color(0xFF374151),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      TextButton.icon(
                                        onPressed: () async {
                                          final link = (item['invite_link'] ?? '')
                                              .toString()
                                              .trim();
                                          final uri = Uri.tryParse(link);
                                          if (uri == null) return;
                                          await launchUrl(
                                            uri,
                                            mode: LaunchMode.externalApplication,
                                          );
                                        },
                                        icon: const Icon(Icons.open_in_new_rounded),
                                        label: const Text('Abrir'),
                                      ),
                                      TextButton.icon(
                                        onPressed: () {
                                          Navigator.pushNamed(
                                            context,
                                            AppRoutes.whatsappGroupForm,
                                            arguments: item,
                                          );
                                        },
                                        icon: const Icon(Icons.edit_rounded),
                                        label: const Text('Editar'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
