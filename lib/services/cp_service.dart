import 'dart:convert';
import 'package:flutter/services.dart';

class CpService {
  static Map<String, dynamic>? _cpData;

  static Future<void> load() async {
    try {
      final jsonString = await rootBundle.loadString('assets/cp_catalog.json');
      final decoded = json.decode(jsonString);

      if (decoded is Map<String, dynamic>) {
        _cpData = decoded;
      } else {
        _cpData = {};
      }
    } catch (e) {
      _cpData = {};
      rethrow;
    }
  }

  static bool get isLoaded => _cpData != null;

  static Map<String, String>? getDataByCp(String cp) {
    if (_cpData == null) return null;

    final cleanCp = cp.replaceAll(RegExp(r'[^0-9]'), '').trim();
    if (cleanCp.length != 5) return null;

    final data = _cpData![cleanCp];
    if (data == null || data is! Map<String, dynamic>) return null;

    return {
      'estado': (data['estado'] ?? '').toString(),
      'municipio': (data['municipio'] ?? '').toString(),
    };
  }
}