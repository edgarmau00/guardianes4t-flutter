class PromotedRecord {
  final String localId;
  final String? remoteId;
  final String capturistId;
  final String registeredByUserId;
  final String registeredByUserEmail;
  final String? ownerAdminUserId;
  final String? ownerAdminName;
  final String? ownerAdminEmail;
  final String? ownerLeaderLocalId;
  final String? ownerLeaderRemoteId;
  final String? ownerLeaderAuthUserId;
  final String? ownerLeaderName;
  final String? ownerPromoterUserId;
  final String? ownerPromoterName;
  final String? imagePath;
  final String claveElectoral;
  final String sexo;
  final String nombre;
  final String apellidoPaterno;
  final String apellidoMaterno;
  final String direccion;
  final String codigoPostal;
  final String vigencia;
  final String seccionElectoral;
  final String fechaNacimiento;
  final String curp;
  final String estado;
  final String municipio;
  final String telefono;
  final String whatsapp;
  final bool discapacidad;
  final int syncStatus; // 0 pendiente, 1 sincronizado, 2 error
  final String createdAt;

  PromotedRecord({
    required this.localId,
    this.remoteId,
    required this.capturistId,
    required this.registeredByUserId,
    required this.registeredByUserEmail,
    this.ownerAdminUserId,
    this.ownerAdminName,
    this.ownerAdminEmail,
    this.ownerLeaderLocalId,
    this.ownerLeaderRemoteId,
    this.ownerLeaderAuthUserId,
    this.ownerLeaderName,
    this.ownerPromoterUserId,
    this.ownerPromoterName,
    this.imagePath,
    required this.claveElectoral,
    required this.sexo,
    required this.nombre,
    required this.apellidoPaterno,
    required this.apellidoMaterno,
    required this.direccion,
    required this.codigoPostal,
    required this.vigencia,
    required this.seccionElectoral,
    required this.fechaNacimiento,
    required this.curp,
    required this.estado,
    required this.municipio,
    required this.telefono,
    required this.whatsapp,
    required this.discapacidad,
    required this.syncStatus,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'local_id': localId,
      'remote_id': remoteId,
      'capturist_id': capturistId,
      'registered_by_user_id': registeredByUserId,
      'registered_by_user_email': registeredByUserEmail,
      'owner_admin_user_id': ownerAdminUserId,
      'owner_admin_name': ownerAdminName,
      'owner_admin_email': ownerAdminEmail,
      'owner_leader_local_id': ownerLeaderLocalId,
      'owner_leader_remote_id': ownerLeaderRemoteId,
      'owner_leader_auth_user_id': ownerLeaderAuthUserId,
      'owner_leader_name': ownerLeaderName,
      'owner_promoter_user_id': ownerPromoterUserId,
      'owner_promoter_name': ownerPromoterName,
      'image_path': imagePath,
      'clave_electoral': claveElectoral,
      'sexo': sexo,
      'nombre': nombre,
      'apellido_paterno': apellidoPaterno,
      'apellido_materno': apellidoMaterno,
      'direccion': direccion,
      'codigo_postal': codigoPostal,
      'vigencia': vigencia,
      'seccion_electoral': seccionElectoral,
      'fecha_nacimiento': fechaNacimiento,
      'curp': curp,
      'estado': estado,
      'municipio': municipio,
      'telefono': telefono,
      'whatsapp': whatsapp,
      'discapacidad': discapacidad ? 1 : 0,
      'sync_status': syncStatus,
      'created_at': createdAt,
    };
  }

  factory PromotedRecord.fromMap(Map<String, dynamic> map) {
    return PromotedRecord(
      localId: map['local_id'],
      remoteId: map['remote_id'],
      capturistId: map['capturist_id'],
      registeredByUserId:
          (map['registered_by_user_id'] ?? map['capturist_id'] ?? '').toString(),
      registeredByUserEmail:
          (map['registered_by_user_email'] ?? '').toString(),
      ownerAdminUserId: map['owner_admin_user_id']?.toString(),
      ownerAdminName: map['owner_admin_name']?.toString(),
      ownerAdminEmail: map['owner_admin_email']?.toString(),
      ownerLeaderLocalId: map['owner_leader_local_id']?.toString(),
      ownerLeaderRemoteId: map['owner_leader_remote_id']?.toString(),
      ownerLeaderAuthUserId: map['owner_leader_auth_user_id']?.toString(),
      ownerLeaderName: map['owner_leader_name']?.toString(),
      ownerPromoterUserId: map['owner_promoter_user_id']?.toString(),
      ownerPromoterName: map['owner_promoter_name']?.toString(),
      imagePath: map['image_path'],
      claveElectoral: map['clave_electoral'] ?? '',
      sexo: map['sexo'] ?? '',
      nombre: map['nombre'] ?? '',
      apellidoPaterno: map['apellido_paterno'] ?? '',
      apellidoMaterno: map['apellido_materno'] ?? '',
      direccion: map['direccion'] ?? '',
      codigoPostal: map['codigo_postal'] ?? '',
      vigencia: map['vigencia'] ?? '',
      seccionElectoral: map['seccion_electoral'] ?? '',
      fechaNacimiento: map['fecha_nacimiento'] ?? '',
      curp: map['curp'] ?? '',
      estado: map['estado'] ?? '',
      municipio: map['municipio'] ?? '',
      telefono: map['telefono'] ?? '',
      whatsapp: map['whatsapp'] ?? '',
      discapacidad: map['discapacidad'] == 1,
      syncStatus: map['sync_status'] ?? 0,
      createdAt: map['created_at'],
    );
  }

  String get nombreCompleto =>
      '$nombre $apellidoPaterno $apellidoMaterno'.trim();
}
