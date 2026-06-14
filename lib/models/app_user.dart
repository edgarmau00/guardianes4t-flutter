import 'dart:convert';

class AppUser {
  final String uid;
  final String email;
  final String displayName;
  final String phone;
  final String role;
  final String? leaderId;
  final String? parentLeaderId;
  final String? rootLeaderId;
  final String? ownerAdminUserId;
  final String? ownerAdminName;
  final String? ownerAdminEmail;
  final String? ownerLeaderUserId;
  final String? registeredByUserId;
  final String? registeredByUserEmail;
  final String? registeredByUserName;
  final String? parentLeaderAuthUserId;
  final String? parentLeaderName;
  final String? rootLeaderAuthUserId;
  final String? rootLeaderName;
  final int hierarchyLevel;

  const AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.phone,
    required this.role,
    this.leaderId,
    this.parentLeaderId,
    this.rootLeaderId,
    this.ownerAdminUserId,
    this.ownerAdminName,
    this.ownerAdminEmail,
    this.ownerLeaderUserId,
    this.registeredByUserId,
    this.registeredByUserEmail,
    this.registeredByUserName,
    this.parentLeaderAuthUserId,
    this.parentLeaderName,
    this.rootLeaderAuthUserId,
    this.rootLeaderName,
    this.hierarchyLevel = 0,
  });

  factory AppUser.fromApi(Map<String, dynamic> json) {
    return AppUser(
      uid: (json['id'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      displayName: (json['full_name'] ?? '').toString(),
      phone: (json['phone'] ?? '').toString(),
      role: (json['role'] ?? '').toString(),
      leaderId: _nullableString(json['leader_id']),
      parentLeaderId: _nullableString(json['parent_leader_id']),
      rootLeaderId: _nullableString(json['root_leader_id']),
      ownerAdminUserId: _nullableString(json['owner_admin_user_id']),
      ownerAdminName: _nullableString(json['owner_admin_name']),
      ownerAdminEmail: _nullableString(json['owner_admin_email']),
      ownerLeaderUserId: _nullableString(json['owner_leader_user_id']),
      registeredByUserId: _nullableString(json['registered_by_user_id']),
      registeredByUserEmail: _nullableString(json['registered_by_user_email']),
      registeredByUserName: _nullableString(json['registered_by_user_name']),
      parentLeaderAuthUserId:
          _nullableString(json['parent_leader_auth_user_id']),
      parentLeaderName: _nullableString(json['parent_leader_name']),
      rootLeaderAuthUserId: _nullableString(json['root_leader_auth_user_id']),
      rootLeaderName: _nullableString(json['root_leader_name']),
      hierarchyLevel: int.tryParse((json['hierarchy_level'] ?? '0').toString()) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': uid,
      'email': email,
      'full_name': displayName,
      'phone': phone,
      'role': role,
      'leader_id': leaderId,
      'parent_leader_id': parentLeaderId,
      'root_leader_id': rootLeaderId,
      'owner_admin_user_id': ownerAdminUserId,
      'owner_admin_name': ownerAdminName,
      'owner_admin_email': ownerAdminEmail,
      'owner_leader_user_id': ownerLeaderUserId,
      'registered_by_user_id': registeredByUserId,
      'registered_by_user_email': registeredByUserEmail,
      'registered_by_user_name': registeredByUserName,
      'parent_leader_auth_user_id': parentLeaderAuthUserId,
      'parent_leader_name': parentLeaderName,
      'root_leader_auth_user_id': rootLeaderAuthUserId,
      'root_leader_name': rootLeaderName,
      'hierarchy_level': hierarchyLevel,
    };
  }

  String toStorageJson() => jsonEncode(toJson());

  factory AppUser.fromStorageJson(String value) {
    return AppUser.fromApi(jsonDecode(value) as Map<String, dynamic>);
  }

  static String? _nullableString(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }
}
