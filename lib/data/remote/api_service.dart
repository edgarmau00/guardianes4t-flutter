import '../models/promoted_record.dart';
import '../../models/app_user.dart';
import '../../services/api_client.dart';
import '../../services/auth_service.dart';

class ApiService {
  final ApiClient _client = ApiClient.instance;
  final AuthService _auth = AuthService();

  Future<String> fetchCurrentAdminRole() async {
    final user = _auth.currentUser ?? await _auth.refreshCurrentUser();
    final role = user?.role ?? '';
    return role == 'superadmin' || role == 'admin' ? role : '';
  }

  Future<bool> isCurrentUserAdmin() async {
    final user = _auth.currentUser ?? await _auth.refreshCurrentUser();
    return user?.role == 'admin' || user?.role == 'superadmin';
  }

  Future<bool> isCurrentUserSuperadmin() async {
    final user = _auth.currentUser ?? await _auth.refreshCurrentUser();
    return user?.role == 'superadmin';
  }

  Future<Map<String, dynamic>> uploadPromoted(PromotedRecord record) async {
    final response = await _client.postJson(
      '/api/promoted',
      bearerToken: _requireToken(),
      body: {
        'claveElectoral': record.claveElectoral,
        'sexo': record.sexo,
        'nombre': record.nombre,
        'apellidoPaterno': record.apellidoPaterno,
        'apellidoMaterno': record.apellidoMaterno,
        'direccion': record.direccion,
        'codigoPostal': record.codigoPostal,
        'vigencia': record.vigencia,
        'seccionElectoral': record.seccionElectoral,
        'fechaNacimiento': record.fechaNacimiento,
        'curp': record.curp,
        'estado': record.estado,
        'municipio': record.municipio,
        'telefono': record.telefono,
        'whatsapp': record.whatsapp,
        'discapacidad': record.discapacidad,
      },
    );

    final item = response['item'] as Map<String, dynamic>;
    final assignedLeaderUserId =
        _nullableString(item['assigned_leader_user_id']) ??
            record.ownerLeaderAuthUserId ??
            record.ownerLeaderRemoteId ??
            record.ownerLeaderLocalId;

    return {
      ...record.toMap(),
      'remote_id': (item['id'] ?? '').toString(),
      'capturist_id':
          (item['created_by_user_id'] ?? record.capturistId).toString(),
      'registered_by_user_id':
          (item['registered_by_user_id'] ?? item['created_by_user_id'] ?? record.registeredByUserId).toString(),
      'registered_by_user_email':
          (item['registered_by_user_email'] ?? record.registeredByUserEmail).toString(),
      'owner_admin_user_id':
          (item['owner_admin_user_id'] ?? record.ownerAdminUserId ?? '').toString(),
      'owner_admin_name':
          (item['owner_admin_name'] ?? record.ownerAdminName ?? '').toString(),
      'owner_admin_email':
          (item['owner_admin_email'] ?? record.ownerAdminEmail ?? '').toString(),
      'owner_leader_local_id': assignedLeaderUserId,
      'owner_leader_remote_id': assignedLeaderUserId,
      'owner_leader_auth_user_id': assignedLeaderUserId,
      'owner_leader_name':
          (item['owner_leader_name'] ?? record.ownerLeaderName ?? '').toString(),
      'owner_promoter_user_id':
          (item['owner_promoter_user_id'] ?? record.ownerPromoterUserId ?? '').toString(),
      'owner_promoter_name':
          (item['owner_promoter_name'] ?? record.ownerPromoterName ?? '').toString(),
      'sync_status': 1,
      'sync_message': 'Sincronizado correctamente',
      'created_at': _toIsoString(item['created_at']) ?? record.createdAt,
    };
  }

  Future<Map<String, dynamic>> uploadLeader(Map<String, dynamic> leader) async {
    final parentLeaderId = _nullableString(
      leader['parent_leader_remote_id'] ?? leader['parent_leader_local_id'],
    );
    final body = <String, dynamic>{
      'email': (leader['email'] ?? '').toString().trim().toLowerCase(),
      'password': (leader['password'] ?? '').toString().trim(),
      'fullName': (leader['full_name'] ?? '').toString().trim(),
      'phone': (leader['phone'] ?? '').toString().trim(),
      'leaderRole': (leader['leader_role'] ?? 'leader_parent').toString(),
      'targetAdminId': _nullableString(leader['owner_admin_user_id']),
    };

    if (parentLeaderId != null) {
      body['parentLeaderId'] = parentLeaderId;
    }

    final response = await _client.postJson(
      '/api/leaders',
      bearerToken: _requireToken(),
      body: body,
    );

    final createdLeader = response['item'] as Map<String, dynamic>;
    final role = (leader['leader_role'] ?? 'leader_parent').toString().trim();
    final leaderUserId = (createdLeader['id'] ?? '').toString();
    final createdParentLeaderId =
        _nullableString(createdLeader['parent_leader_id']) ??
        _nullableString(leader['parent_leader_auth_user_id']) ??
        _nullableString(leader['parent_leader_remote_id']) ??
        _nullableString(leader['parent_leader_local_id']);
    final rootLeaderId = _nullableString(createdLeader['root_leader_id']) ??
        _nullableString(leader['root_leader_auth_user_id']) ??
        _nullableString(leader['root_leader_remote_id']) ??
        _nullableString(leader['root_leader_local_id']) ??
        leaderUserId;

    return {
      ...leader,
      'remote_id': leaderUserId,
      'auth_user_id': leaderUserId,
      'owner_admin_user_id':
          (createdLeader['owner_admin_user_id'] ?? leader['owner_admin_user_id'] ?? '').toString(),
      'owner_admin_name':
          (createdLeader['owner_admin_name'] ?? leader['owner_admin_name'] ?? '').toString(),
      'owner_admin_email':
          (createdLeader['owner_admin_email'] ?? leader['owner_admin_email'] ?? '').toString(),
      'parent_leader_remote_id': createdParentLeaderId,
      'parent_leader_auth_user_id': createdParentLeaderId,
      'root_leader_remote_id': rootLeaderId,
      'root_leader_auth_user_id': rootLeaderId,
      'root_leader_name': role == 'leader_parent'
          ? (createdLeader['full_name'] ?? '').toString()
          : leader['root_leader_name'],
      'email': (createdLeader['email'] ?? '').toString(),
      'full_name': (createdLeader['full_name'] ?? '').toString(),
      'phone': (createdLeader['phone'] ?? leader['phone']).toString(),
      'hierarchy_level':
          createdLeader['hierarchy_level'] ?? leader['hierarchy_level'] ?? 1,
      'sync_status': 1,
      'sync_message': 'Sincronizado correctamente',
      'created_at': _toIsoString(createdLeader['created_at']) ??
          (leader['created_at'] ?? DateTime.now().toIso8601String()),
    };
  }

  Future<Map<String, dynamic>> uploadWhatsappGroup(
      Map<String, dynamic> group) async {
    final remoteId = _nullableString(group['remote_id']) ??
        _nullableString(group['local_id']);
    final body = {
      'name': (group['name'] ?? '').toString().trim(),
      'inviteLink': (group['invite_link'] ?? '').toString().trim(),
      'notes': (group['notes'] ?? '').toString().trim(),
      'active': (group['active'] ?? 1) == 1,
    };

    final response = remoteId == null
        ? await _client.postJson(
            '/api/whatsapp-groups',
            bearerToken: _requireToken(),
            body: body,
          )
        : await _client.patchJson(
            '/api/whatsapp-groups/$remoteId',
            bearerToken: _requireToken(),
            body: body,
          );

    final item = response['item'] as Map<String, dynamic>;
    return {
      ...group,
      'remote_id': (item['id'] ?? '').toString(),
      'active': (item['active'] ?? true) == true ? 1 : 0,
      'sync_status': 1,
      'sync_message': 'Sincronizado correctamente',
      'created_at': _toIsoString(item['created_at']) ??
          (group['created_at'] ?? DateTime.now().toIso8601String()),
    };
  }

  Future<List<Map<String, dynamic>>> fetchPromotedByCurrentCapturist() async {
    final response = await _client.getJson(
      '/api/promoted',
      bearerToken: _requireToken(),
    );

    final items = (response['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return items.map(_mapRemotePromotedToLocalRow).toList();
  }

  Future<List<Map<String, dynamic>>> fetchLeadersByCurrentCapturist() async {
    final response = await _client.getJson(
      '/api/leaders',
      bearerToken: _requireToken(),
    );

    final items = (response['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return items.map(_mapRemoteLeaderToLocalRow).toList();
  }

  Future<List<Map<String, dynamic>>> fetchWhatsappGroups() async {
    final response = await _client.getJson(
      '/api/whatsapp-groups',
      bearerToken: _requireToken(),
    );

    final items = (response['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return items.map((item) {
      return {
        'local_id': (item['id'] ?? '').toString(),
        'remote_id': (item['id'] ?? '').toString(),
        'name': (item['name'] ?? '').toString(),
        'invite_link': (item['invite_link'] ?? '').toString(),
        'notes': (item['notes'] ?? '').toString(),
        'active': (item['active'] ?? true) == true ? 1 : 0,
        'created_by_user_id': (item['created_by_user_id'] ?? '').toString(),
        'created_by_user_email': '',
        'sync_status': 1,
        'sync_message': 'Sincronizado correctamente',
        'created_at': _toIsoString(item['created_at']) ??
            DateTime.now().toIso8601String(),
      };
    }).toList();
  }

  Future<Map<String, dynamic>?> fetchCurrentLeaderProfile() async {
    final user = _auth.currentUser ?? await _auth.refreshCurrentUser();
    if (user == null || user.leaderId == null) {
      return null;
    }

    return _mapSessionUserToLeaderRow(user);
  }

  Future<bool> promotedExistsByClaveElectoral(String claveElectoral) async {
    final response = await _client.getJson(
      '/api/promoted/exists',
      bearerToken: _requireToken(),
      query: {
        'claveElectoral': claveElectoral.trim().toUpperCase(),
      },
    );

    return response['exists'] == true;
  }

  Future<bool> leaderExists({
    required String email,
    required String phone,
  }) async {
    final response = await _client.getJson(
      '/api/leaders/exists',
      bearerToken: _requireToken(),
      query: {
        'email': email.trim().toLowerCase(),
        'phone': phone.trim(),
      },
    );

    return response['exists'] == true;
  }

  Future<Map<String, dynamic>> fetchBootstrap() {
    return _client.getJson(
      '/api/sync/bootstrap',
      bearerToken: _requireToken(),
    );
  }

  Map<String, dynamic> _mapRemoteLeaderToLocalRow(Map<String, dynamic> item) {
    return {
      'local_id': (item['id'] ?? '').toString(),
      'remote_id': (item['id'] ?? '').toString(),
      'capturist_id': (item['registered_by_user_id'] ?? '').toString(),
      'owner_admin_user_id': _nullableString(item['owner_admin_user_id']),
      'owner_admin_name': _nullableString(item['owner_admin_name']),
      'owner_admin_email': _nullableString(item['owner_admin_email']),
      'registered_by_user_id': (item['registered_by_user_id'] ?? '').toString(),
      'registered_by_user_email':
          (item['registered_by_user_email'] ?? '').toString(),
      'registered_by_user_name':
          (item['registered_by_user_name'] ?? '').toString(),
      'auth_user_id': (item['user_id'] ?? '').toString(),
      'leader_role': (item['leader_role'] ?? '').toString(),
      'parent_leader_local_id': _nullableString(item['parent_leader_id']),
      'parent_leader_remote_id': _nullableString(item['parent_leader_id']),
      'parent_leader_auth_user_id':
          _nullableString(item['parent_leader_auth_user_id']),
      'parent_leader_name': _nullableString(item['parent_leader_name']),
      'root_leader_local_id': _nullableString(item['root_leader_id']),
      'root_leader_remote_id': _nullableString(item['root_leader_id']),
      'root_leader_auth_user_id':
          _nullableString(item['root_leader_auth_user_id']),
      'root_leader_name': _nullableString(item['root_leader_name']),
      'hierarchy_level':
          int.tryParse((item['hierarchy_level'] ?? '1').toString()) ?? 1,
      'email': (item['email'] ?? '').toString(),
      'password': '',
      'full_name': (item['full_name'] ?? '').toString(),
      'phone': (item['phone'] ?? '').toString(),
      'sync_status': 1,
      'sync_message': 'Sincronizado correctamente',
      'created_at':
          _toIsoString(item['created_at']) ?? DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic> _mapRemotePromotedToLocalRow(Map<String, dynamic> item) {
    return {
      'local_id': (item['id'] ?? '').toString(),
      'remote_id': (item['id'] ?? '').toString(),
      'capturist_id': (item['created_by_user_id'] ?? '').toString(),
      'registered_by_user_id':
          (item['registered_by_user_id'] ?? item['created_by_user_id'] ?? '')
              .toString(),
      'registered_by_user_email':
          (item['registered_by_user_email'] ?? item['capturist_email'] ?? '')
              .toString(),
      'owner_admin_user_id': _nullableString(item['owner_admin_user_id']),
      'owner_admin_name': _nullableString(item['owner_admin_name']),
      'owner_admin_email': _nullableString(item['owner_admin_email']),
      'owner_leader_local_id': _nullableString(item['owner_leader_id']),
      'owner_leader_remote_id': _nullableString(item['owner_leader_id']),
      'owner_leader_auth_user_id':
          _nullableString(item['owner_leader_auth_user_id']),
      'owner_leader_name': _nullableString(item['owner_leader_name']),
      'owner_promoter_user_id': _nullableString(item['owner_promoter_user_id']),
      'owner_promoter_name': _nullableString(item['owner_promoter_name']),
      'image_path': null,
      'clave_electoral': (item['clave_electoral'] ?? '').toString(),
      'sexo': (item['sexo'] ?? '').toString(),
      'nombre': (item['nombre'] ?? '').toString(),
      'apellido_paterno': (item['apellido_paterno'] ?? '').toString(),
      'apellido_materno': (item['apellido_materno'] ?? '').toString(),
      'direccion': (item['direccion'] ?? '').toString(),
      'codigo_postal': (item['codigo_postal'] ?? '').toString(),
      'vigencia': (item['vigencia'] ?? '').toString(),
      'seccion_electoral': (item['seccion_electoral'] ?? '').toString(),
      'fecha_nacimiento': (item['fecha_nacimiento'] ?? '').toString(),
      'curp': (item['curp'] ?? '').toString(),
      'estado': (item['estado'] ?? '').toString(),
      'municipio': (item['municipio'] ?? '').toString(),
      'telefono': (item['telefono'] ?? '').toString(),
      'whatsapp': (item['whatsapp'] ?? '').toString(),
      'discapacidad': (item['discapacidad'] ?? false) == true ? 1 : 0,
      'sync_status': 1,
      'sync_message': 'Sincronizado correctamente',
      'created_at':
          _toIsoString(item['created_at']) ?? DateTime.now().toIso8601String(),
    };
  }

  Map<String, dynamic> _mapSessionUserToLeaderRow(AppUser user) {
    return {
      'local_id': user.leaderId,
      'remote_id': user.leaderId,
      'capturist_id': user.uid,
      'registered_by_user_id': user.registeredByUserId ?? user.uid,
      'registered_by_user_email': user.registeredByUserEmail ?? '',
      'registered_by_user_name': user.registeredByUserName ?? '',
      'auth_user_id': user.uid,
      'leader_role': user.role,
      'parent_leader_local_id': user.parentLeaderId,
      'parent_leader_remote_id': user.parentLeaderId,
      'parent_leader_auth_user_id': user.parentLeaderAuthUserId,
      'parent_leader_name': user.parentLeaderName,
      'root_leader_local_id': user.rootLeaderId,
      'root_leader_remote_id': user.rootLeaderId,
      'root_leader_auth_user_id': user.rootLeaderAuthUserId,
      'root_leader_name': user.rootLeaderName,
      'owner_admin_user_id': user.ownerAdminUserId,
      'owner_admin_name': user.ownerAdminName,
      'owner_admin_email': user.ownerAdminEmail,
      'hierarchy_level': user.hierarchyLevel,
      'email': user.email,
      'password': '',
      'full_name': user.displayName,
      'phone': user.phone,
      'sync_status': 1,
      'sync_message': 'Sincronizado correctamente',
      'created_at': DateTime.now().toIso8601String(),
    };
  }

  String _requireToken() {
    final token = _auth.accessToken;
    if (token == null || token.trim().isEmpty) {
      throw const ApiException(401, 'No hay sesion activa');
    }
    return token;
  }

  String? _nullableString(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }

  String? _toIsoString(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }
}
