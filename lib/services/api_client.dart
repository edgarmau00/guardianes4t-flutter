import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  Future<Map<String, dynamic>> getJson(
    String path, {
    String? bearerToken,
    Map<String, String>? query,
  }) async {
    final response = await http.get(
      _buildUri(path, query),
      headers: _buildHeaders(bearerToken),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    String? bearerToken,
    Object? body,
  }) async {
    final response = await http.post(
      _buildUri(path),
      headers: _buildHeaders(bearerToken),
      body: jsonEncode(body ?? const <String, dynamic>{}),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> patchJson(
    String path, {
    String? bearerToken,
    Object? body,
  }) async {
    final response = await http.patch(
      _buildUri(path),
      headers: _buildHeaders(bearerToken),
      body: jsonEncode(body ?? const <String, dynamic>{}),
    );
    return _decode(response);
  }

  Uri _buildUri(String path, [Map<String, String>? query]) {
    final base = Uri.parse(AppConfig.apiBaseUrl);
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return base.replace(
      path: '${base.path}$normalizedPath'.replaceAll('//', '/'),
      queryParameters: query == null || query.isEmpty ? null : query,
    );
  }

  Map<String, String> _buildHeaders(String? bearerToken) {
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (bearerToken != null && bearerToken.trim().isNotEmpty)
        'Authorization': 'Bearer $bearerToken',
    };
  }

  Map<String, dynamic> _decode(http.Response response) {
    final hasBody = response.body.trim().isNotEmpty;
    final payload = hasBody
        ? jsonDecode(response.body) as Map<String, dynamic>
        : <String, dynamic>{};

    if (response.statusCode >= 400) {
      throw ApiException(
        response.statusCode,
        (payload['message'] ?? 'Request failed').toString(),
      );
    }

    return payload;
  }
}
