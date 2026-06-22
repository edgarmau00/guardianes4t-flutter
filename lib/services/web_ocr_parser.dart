class WebOcrParser {
  Map<String, String> parse(String rawText) {
    final normalized = _normalize(rawText);
    final lines = normalized
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();

    final claveElectoral = _extractClaveElectoral(normalized);
    final curp = _extractCurp(normalized);
    final fechaNacimiento = _extractFechaNacimiento(normalized);
    final vigencia = _extractVigencia(normalized);
    final seccion = _extractSeccion(normalized);
    final sexo = _extractSexo(normalized);
    final codigoPostal = _extractCodigoPostal(normalized);
    final direccion = _extractDireccion(lines);
    final nameParts = _extractNameParts(lines);

    return {
      'rawText': normalized,
      'processingMode': 'web_tesseract',
      'claveElectoral': claveElectoral,
      'claveElector': claveElectoral,
      'curp': curp,
      'fechaNacimiento': fechaNacimiento,
      'vigencia': vigencia,
      'seccionElectoral': seccion,
      'seccion': seccion,
      'sexo': sexo,
      'codigoPostal': codigoPostal,
      'direccion': direccion,
      'nombre': nameParts['nombre'] ?? '',
      'apellidoPaterno': nameParts['apellidoPaterno'] ?? '',
      'apellidoMaterno': nameParts['apellidoMaterno'] ?? '',
      'estado': _extractEstado(lines, direccion),
      'municipio': _extractMunicipio(lines, direccion),
    };
  }

  String _normalize(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAllMapped(
          RegExp(r'[ \t]+'),
          (_) => ' ',
        )
        .trim();
  }

  String _extractClaveElectoral(String text) {
    final match = RegExp(
      r'(?:[A-Z]{6}[0-9]{6}[0-9]{2}[HM][0-9]{3}|[A-Z]{5}[0-9]{6}[0-9]{2}[HM][0-9]{4})',
    ).firstMatch(text.replaceAll(RegExp(r'[^A-Z0-9]'), ''));
    return match?.group(0) ?? '';
  }

  String _extractCurp(String text) {
    final match = RegExp(
      r'[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}',
    ).firstMatch(text.replaceAll(RegExp(r'[^A-Z0-9]'), ''));
    return match?.group(0) ?? '';
  }

  String _extractFechaNacimiento(String text) {
    final match = RegExp(r'\b\d{2}[\/\-\.]\d{2}[\/\-\.]\d{4}\b').firstMatch(text);
    return match?.group(0)?.replaceAll('-', '/')?.replaceAll('.', '/') ?? '';
  }

  String _extractVigencia(String text) {
    final match = RegExp(r'\b\d{4}\s*[-\/]\s*\d{4}\b').firstMatch(text);
    return match?.group(0)?.replaceAll('/', '-')?.replaceAll(' ', '') ?? '';
  }

  String _extractSeccion(String text) {
    final labelMatch = RegExp(
      r'SECCI[OÓ]N[:\s]*([0-9]{3,4})',
      caseSensitive: false,
    ).firstMatch(text);
    if (labelMatch != null) {
      return labelMatch.group(1) ?? '';
    }

    final fallback = RegExp(r'\b[0-9]{3,4}\b').allMatches(text).toList();
    if (fallback.isEmpty) return '';
    return fallback.last.group(0) ?? '';
  }

  String _extractSexo(String text) {
    if (RegExp(r'\bMUJER\b', caseSensitive: false).hasMatch(text)) {
      return 'M';
    }
    if (RegExp(r'\bHOMBRE\b', caseSensitive: false).hasMatch(text)) {
      return 'H';
    }
    final match = RegExp(r'SEXO[:\s]*([HM])', caseSensitive: false).firstMatch(text);
    return match?.group(1)?.toUpperCase() ?? '';
  }

  String _extractCodigoPostal(String text) {
    final matches = RegExp(r'\b\d{5}\b').allMatches(text).toList();
    if (matches.isEmpty) return '';
    return matches.last.group(0) ?? '';
  }

  String _extractDireccion(List<String> lines) {
    final labels = [
      'DOMICILIO',
      'DIRECCION',
    ];

    for (var i = 0; i < lines.length; i++) {
      final upper = lines[i].toUpperCase();
      for (final label in labels) {
        if (upper.contains(label)) {
          final cleaned = lines[i]
              .replaceAll(RegExp(label, caseSensitive: false), '')
              .replaceAll(':', '')
              .trim();
          if (cleaned.isNotEmpty) {
            return cleaned;
          }
          if (i + 1 < lines.length) {
            return lines[i + 1];
          }
        }
      }
    }

    final addressLike = lines.where((line) {
      final upper = line.toUpperCase();
      return upper.contains('CALLE') ||
          upper.contains('AV') ||
          upper.contains('COL') ||
          upper.contains('MANZANA') ||
          upper.contains('LOTE') ||
          RegExp(r'\d').hasMatch(upper);
    }).toList();

    return addressLike.isNotEmpty ? addressLike.first : '';
  }

  Map<String, String> _extractNameParts(List<String> lines) {
    final filtered = lines.where((line) {
      final upper = line.toUpperCase();
      return !upper.contains('CLAVE') &&
          !upper.contains('CURP') &&
          !upper.contains('DOMICILIO') &&
          !upper.contains('DIRECCION') &&
          !upper.contains('SECCI') &&
          !upper.contains('VIGENCIA') &&
          !upper.contains('NACIMIENTO') &&
          !RegExp(r'\d{4,}').hasMatch(upper);
    }).toList();

    String candidate = '';
    for (final line in filtered) {
      final upper = line.toUpperCase();
      if (upper.split(' ').where((e) => e.isNotEmpty).length >= 2 &&
          !upper.contains('INSTITUTO') &&
          !upper.contains('ESTADOS') &&
          !upper.contains('MEXICANOS')) {
        candidate = upper;
        break;
      }
    }

    if (candidate.isEmpty) {
      return const {
        'nombre': '',
        'apellidoPaterno': '',
        'apellidoMaterno': '',
      };
    }

    final parts = candidate
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (parts.length == 1) {
      return {
        'nombre': parts.first,
        'apellidoPaterno': '',
        'apellidoMaterno': '',
      };
    }
    if (parts.length == 2) {
      return {
        'nombre': parts[1],
        'apellidoPaterno': parts[0],
        'apellidoMaterno': '',
      };
    }

    return {
      'apellidoPaterno': parts[0],
      'apellidoMaterno': parts[1],
      'nombre': parts.sublist(2).join(' '),
    };
  }

  String _extractEstado(List<String> lines, String direccion) {
    final searchable = [...lines, direccion];
    for (final line in searchable) {
      final upper = line.toUpperCase();
      if (upper.contains('JALISCO')) return 'JALISCO';
      if (upper.contains('MICHOACAN')) return 'MICHOACAN';
      if (upper.contains('GUANAJUATO')) return 'GUANAJUATO';
      if (upper.contains('CDMX') || upper.contains('CIUDAD DE MEXICO')) {
        return 'CIUDAD DE MEXICO';
      }
      if (upper.contains('MEXICO')) return 'MEXICO';
      if (upper.contains('NUEVO LEON')) return 'NUEVO LEON';
      if (upper.contains('PUEBLA')) return 'PUEBLA';
      if (upper.contains('VERACRUZ')) return 'VERACRUZ';
    }
    return '';
  }

  String _extractMunicipio(List<String> lines, String direccion) {
    final searchable = [...lines, direccion];
    for (final line in searchable) {
      final upper = line.toUpperCase();
      if (upper.contains('GUADALAJARA')) return 'GUADALAJARA';
      if (upper.contains('ZAPOPAN')) return 'ZAPOPAN';
      if (upper.contains('MORELIA')) return 'MORELIA';
      if (upper.contains('LEON')) return 'LEON';
      if (upper.contains('MONTERREY')) return 'MONTERREY';
      if (upper.contains('PUEBLA')) return 'PUEBLA';
      if (upper.contains('VERACRUZ')) return 'VERACRUZ';
    }
    return '';
  }
}
