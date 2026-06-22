import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';

class NetworkStatusService {
  Future<bool> hasInternet() async {
    final healthUrl = Uri.parse('${AppConfig.apiBaseUrl}/health');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5);

    try {
      final request = await client.getUrl(healthUrl);
      final response = await request.close();
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (_) {
      try {
        final result = await InternetAddress.lookup('api.guardianes4t.cloud');
        return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
      } catch (error) {
        debugPrint('[NETWORK] Sin conectividad: $error');
        return false;
      }
    } finally {
      client.close(force: true);
    }
  }
}
