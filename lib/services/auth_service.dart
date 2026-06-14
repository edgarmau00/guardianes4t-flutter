import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_user.dart';
import 'api_client.dart';

class AuthService {
  AuthService._();

  static final AuthService _instance = AuthService._();
  factory AuthService() => _instance;

  static const _tokenKey = 'guardianes4t_access_token';
  static const _userKey = 'guardianes4t_session_user';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final ApiClient _client = ApiClient.instance;

  AppUser? _currentUser;
  String? _accessToken;

  AppUser? get currentUser => _currentUser;
  String? get accessToken => _accessToken;
  bool get isLoggedIn =>
      _currentUser != null && (_accessToken?.trim().isNotEmpty ?? false);

  Future<void> initialize() async {
    final token = await _storage.read(key: _tokenKey);
    final rawUser = await _storage.read(key: _userKey);

    if (token == null || token.trim().isEmpty || rawUser == null) {
      _currentUser = null;
      _accessToken = null;
      return;
    }

    _accessToken = token;
    _currentUser = AppUser.fromStorageJson(rawUser);
  }

  Future<void> login({
    required String email,
    required String password,
  }) async {
    final response = await _client.postJson(
      '/api/auth/login',
      body: {
        'email': email.trim().toLowerCase(),
        'password': password.trim(),
      },
    );

    final token = (response['accessToken'] ?? '').toString();
    final user = AppUser.fromApi(response['user'] as Map<String, dynamic>);

    await _saveSession(
      token: token,
      user: user,
    );
  }

  Future<AppUser?> refreshCurrentUser() async {
    if (!isLoggedIn) return null;

    final response = await _client.getJson(
      '/api/auth/me',
      bearerToken: _accessToken,
    );

    final user = AppUser.fromApi(response['user'] as Map<String, dynamic>);
    await _saveSession(
      token: _accessToken!,
      user: user,
    );
    return user;
  }

  Future<void> logout() async {
    _currentUser = null;
    _accessToken = null;
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userKey);
  }

  Future<bool> leaderAccessExists(String email) async {
    if (!isLoggedIn) return false;

    final response = await _client.getJson(
      '/api/leaders/exists',
      bearerToken: _accessToken,
      query: {
        'email': email.trim().toLowerCase(),
      },
    );

    return response['exists'] == true;
  }

  Future<void> updateLeaderAccess({
    required String leaderId,
    required String newEmail,
    required String newPassword,
  }) async {
    if (!isLoggedIn) {
      throw const ApiException(401, 'No hay sesion activa');
    }

    await _client.patchJson(
      '/api/leaders/$leaderId/access',
      bearerToken: _accessToken,
      body: {
        'email': newEmail.trim().toLowerCase(),
        'password': newPassword.trim(),
      },
    );
  }

  Future<void> _saveSession({
    required String token,
    required AppUser user,
  }) async {
    _accessToken = token;
    _currentUser = user;
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _userKey, value: user.toStorageJson());
  }
}
