import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

class NetworkStatusService {
  Future<bool> hasInternet() async {
    final healthUrl = Uri.parse('${AppConfig.apiBaseUrl}/health');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);

    try {
      final request = await client.getUrl(healthUrl);
      final response = await request.close();
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (error) {
      debugPrint('[NETWORK] API no disponible: $error');
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
