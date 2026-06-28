import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class NetworkStatusService {
  Future<bool> hasInternet() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.apiBaseUrl}/health'))
          .timeout(const Duration(seconds: 6));
      return response.statusCode >= 200 && response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }
}
