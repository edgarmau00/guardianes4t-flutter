class OcrValidationResult {
  final Map<String, String> normalizedData;
  final Map<String, String> warnings;
  final Map<String, double> confidence;
  final double globalConfidence;

  OcrValidationResult({
    required this.normalizedData,
    required this.warnings,
    required this.confidence,
    required this.globalConfidence,
  });
}

class OcrValidationService {
  OcrValidationResult validate(Map<String, String> data) {
    final normalized = Map<String, String>.from(data);
    final warnings = <String, String>{};
    final confidence = <String, double>{};

    String clean(String key) => (normalized[key] ?? '').trim();

    String onlyDigits(String value) {
      return value.replaceAll(RegExp(r'[^0-9]'), '');
    }

    String normalizeText(String value) {
      return value
          .replaceAll('\n', ' ')
          .replaceAll('\r', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    String normalizeUpper(String value) {
      return normalizeText(value).toUpperCase();
    }

    String normalizeHuman(String value) {
      return normalizeText(value);
    }

    String stripDocumentFieldLabels(String value) {
      var text = normalizeHuman(value);
      if (text.isEmpty) return '';

      final patterns = <RegExp>[
        RegExp(r'D[O0]M[I1L]C[I1L][I1L][O0QK]', caseSensitive: false),
        RegExp(r'D[O0]M[I1L][C0O][I1L][I1L][O0QK]', caseSensitive: false),
        RegExp(r'DOMICILIO', caseSensitive: false),
        RegExp(r'N[O0]MBR[E3F]', caseSensitive: false),
        RegExp(r'CLAV[E3]\s*D[E3]\s*ELECT[O0]R', caseSensitive: false),
        RegExp(r'CURP', caseSensitive: false),
        RegExp(r'SECC[I1][O0]N', caseSensitive: false),
        RegExp(r'VIGENC[I1]A', caseSensitive: false),
        RegExp(r'SEX[O0]', caseSensitive: false),
        RegExp(r'FECHA\s*D[E3]\s*NAC[I1]M[I1]ENT[O0]', caseSensitive: false),
        RegExp(r'A[NÑ][O0]\s*D[E3]\s*REG[I1]STR[O0]', caseSensitive: false),
        RegExp(r'DIRECC[I1][O0]N', caseSensitive: false),
      ];

      for (final pattern in patterns) {
        text = text.replaceAll(pattern, ' ');
      }

      return normalizeHuman(text);
    }

    String fixCommonNumericOcr(String value) {
      return value
          .replaceAll('O', '0')
          .replaceAll('Q', '0')
          .replaceAll('I', '1')
          .replaceAll('L', '1')
          .replaceAll('Z', '2')
          .replaceAll('S', '5')
          .replaceAll('B', '8');
    }

    String fixCommonAlphaOcr(String value) {
      return value
          .replaceAll('0', 'O')
          .replaceAll('1', 'I')
          .replaceAll('2', 'Z')
          .replaceAll('5', 'S')
          .replaceAll('8', 'B');
    }

    String fixClaveElectoral(String value) {
      final raw = normalizeUpper(value).replaceAll(' ', '');
      if (raw.isEmpty) return raw;

      final chars = raw.split('');
      for (int i = 0; i < chars.length; i++) {
        if (i <= 5) {
          chars[i] = fixCommonAlphaOcr(chars[i]);
        }
        if (i >= 5 && i <= 17) {
          chars[i] = fixCommonNumericOcr(chars[i]);
        }
      }

      return chars.join();
    }

    String fixCurp(String value) {
      final raw = normalizeUpper(value).replaceAll(' ', '');
      if (raw.isEmpty) return raw;

      final chars = raw.split('');
      for (int i = 0; i < chars.length; i++) {
        if (i <= 3 || (i >= 11 && i <= 15)) {
          chars[i] = fixCommonAlphaOcr(chars[i]);
        }
      }
      for (int i = 4; i < chars.length && i <= 9; i++) {
        chars[i] = fixCommonNumericOcr(chars[i]);
      }

      if (chars.length > 10 && chars[10] == 'N') {
        chars[10] = 'H';
      }

      return chars.join();
    }

    String fixSexo(String value) {
      final raw = normalizeUpper(value);
      if (raw == 'HOMBRE') return 'H';
      if (raw == 'MUJER') return 'M';
      if (raw == 'N') return 'H';
      if (raw == 'M') return 'M';
      if (raw.contains('H')) return 'H';
      if (raw.contains('M')) return 'M';
      return '';
    }

    String fixFecha(String value) {
      final raw = normalizeText(value)
          .replaceAll('-', '/')
          .replaceAll('.', '/')
          .replaceAll(RegExp(r'[^0-9/]'), '');

      final direct = RegExp(r'(\d{2})/(\d{2})/(\d{4})').firstMatch(raw);
      if (direct != null) {
        return '${direct.group(1)}/${direct.group(2)}/${direct.group(3)}';
      }

      final digits = onlyDigits(raw);
      if (digits.length >= 8) {
        return '${digits.substring(0, 2)}/${digits.substring(2, 4)}/${digits.substring(4, 8)}';
      }

      return raw;
    }

    String fixVigencia(String value) {
      final raw = normalizeUpper(value)
          .replaceAll(' ', '')
          .replaceAll('/', '-')
          .replaceAll('_', '-')
          .replaceAll('.', '-');

      final direct = RegExp(r'(\d{4})-(\d{4})').firstMatch(raw);
      if (direct != null) {
        return '${direct.group(1)}-${direct.group(2)}';
      }

      final digits = onlyDigits(fixCommonNumericOcr(raw));
      if (digits.length >= 8) {
        return '${digits.substring(0, 4)}-${digits.substring(4, 8)}';
      }

      return raw;
    }

    String fixCp(String value) {
      final digits = onlyDigits(fixCommonNumericOcr(normalizeUpper(value)));
      if (digits.length >= 5) {
        return digits.substring(0, 5);
      }
      return digits;
    }

    String fixSeccion(String value) {
      final digits = onlyDigits(fixCommonNumericOcr(normalizeUpper(value)));
      if (digits.length >= 4) {
        return digits.substring(0, 4);
      }
      return digits;
    }

    String cleanupDireccion(String value) {
      var text = stripDocumentFieldLabels(value);

      if (text.isEmpty) return '';

      final forbiddenPatterns = <RegExp>[
        RegExp(r'CLAVE\s+DE\s+ELECTOR', caseSensitive: false),
        RegExp(r'\bCURP\b', caseSensitive: false),
        RegExp(r'FECHA\s+DE\s+NACIMIENTO', caseSensitive: false),
        RegExp(r'\bSECCI[ÓO]N\b', caseSensitive: false),
        RegExp(r'\bVIGENCIA\b', caseSensitive: false),
        RegExp(r'\bSEXO\b', caseSensitive: false),
        RegExp(r'\bEMISI[ÓO]N\b', caseSensitive: false),
        RegExp(r'A[ÑN]O\s+DE\s+REGISTRO', caseSensitive: false),
        RegExp(r'\b[A-Z]{6}[0-9]{6}[A-Z][0-9]{3}\b'),
        RegExp(r'\b[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}\b'),
        RegExp(r'^\d{4}$'),
      ];

      for (final pattern in forbiddenPatterns) {
        if (pattern.hasMatch(text)) {
          return '';
        }
      }

      if (RegExp(r'^[A-Z\s]+$').hasMatch(text) && text.split(' ').length <= 2) {
        return '';
      }

      return text;
    }

    final clave = fixClaveElectoral(clean('claveElectoral'));
    final sexo = fixSexo(clean('sexo'));
    final nombre = stripDocumentFieldLabels(clean('nombre'));
    final apellidoPaterno = stripDocumentFieldLabels(clean('apellidoPaterno'));
    final apellidoMaterno = stripDocumentFieldLabels(clean('apellidoMaterno'));
    final direccion = cleanupDireccion(clean('direccion'));
    final codigoPostal = fixCp(clean('codigoPostal'));
    final vigencia = fixVigencia(clean('vigencia'));
    final seccion = fixSeccion(clean('seccionElectoral'));
    final fechaNacimiento = fixFecha(clean('fechaNacimiento'));
    final curp = fixCurp(clean('curp'));
    final estado = stripDocumentFieldLabels(clean('estado'));
    final municipio = stripDocumentFieldLabels(clean('municipio'));

    normalized['claveElectoral'] = clave;
    normalized['claveElector'] = clave;
    normalized['sexo'] = sexo;
    normalized['nombre'] = nombre;
    normalized['apellidoPaterno'] = apellidoPaterno;
    normalized['apellidoMaterno'] = apellidoMaterno;
    normalized['direccion'] = direccion;
    normalized['codigoPostal'] = codigoPostal;
    normalized['vigencia'] = vigencia;
    normalized['seccionElectoral'] = seccion;
    normalized['seccion'] = seccion;
    normalized['fechaNacimiento'] = fechaNacimiento;
    normalized['curp'] = curp;
    normalized['estado'] = estado;
    normalized['municipio'] = municipio;

    double scoreByPattern(String key, String value) {
      final v = value.trim();

      if (v.isEmpty) return 0.0;

      switch (key) {
        case 'claveElectoral':
          if (RegExp(
            r'^(?:[A-Z]{6}[0-9]{6}[0-9]{2}[HM][0-9]{3}|[A-Z]{5}[0-9]{6}[0-9]{2}[HM][0-9]{4})$',
          ).hasMatch(v)) {
            return 1.0;
          }
          return v.length >= 17 ? 0.55 : 0.20;

        case 'curp':
          if (RegExp(r'^[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}$').hasMatch(v)) {
            return 1.0;
          }
          return v.length >= 14 ? 0.55 : 0.20;

        case 'fechaNacimiento':
          if (RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(v)) return 1.0;
          return 0.35;

        case 'vigencia':
          if (RegExp(r'^\d{4}-\d{4}$').hasMatch(v)) return 1.0;
          return 0.40;

        case 'codigoPostal':
          if (RegExp(r'^\d{5}$').hasMatch(v)) return 1.0;
          return 0.30;

        case 'seccionElectoral':
          if (RegExp(r'^\d{3,4}$').hasMatch(v)) return 1.0;
          return 0.35;

        case 'sexo':
          if (v == 'H' || v == 'M') return 1.0;
          return 0.25;

        case 'direccion':
          if (v.length >= 8) return 0.90;
          return 0.25;

        case 'nombre':
        case 'apellidoPaterno':
        case 'apellidoMaterno':
        case 'estado':
        case 'municipio':
          if (v.length >= 2) return 0.90;
          return 0.25;

        default:
          return 0.50;
      }
    }

    void validateField(String key, String message) {
      final value = (normalized[key] ?? '').trim();
      final score = scoreByPattern(key, value);
      confidence[key] = score;

      if (value.isEmpty) {
        warnings[key] = message;
        return;
      }

      if (score < 0.60) {
        warnings[key] = '$message (lectura poco confiable)';
      }
    }

    validateField('claveElectoral', 'No se detectó la clave de elector');
    validateField('sexo', 'No se detectó el sexo');
    validateField('nombre', 'No se detectó el nombre');
    validateField('apellidoPaterno', 'No se detectó el apellido paterno');
    validateField('apellidoMaterno', 'No se detectó el apellido materno');
    validateField('direccion', 'No se detectó la dirección');
    validateField('codigoPostal', 'No se detectó el código postal');
    validateField('vigencia', 'No se detectó la vigencia');
    validateField('seccionElectoral', 'No se detectó la sección');
    validateField('fechaNacimiento', 'No se detectó la fecha de nacimiento');
    validateField('curp', 'No se detectó la CURP');
    validateField('estado', 'No se detectó el estado');
    validateField('municipio', 'No se detectó el municipio');

    final importantKeys = [
      'nombre',
      'apellidoPaterno',
      'direccion',
      'codigoPostal',
      'claveElectoral',
      'curp',
      'seccionElectoral',
      'fechaNacimiento',
    ];

    double global = 0.0;
    for (final key in importantKeys) {
      global += confidence[key] ?? 0.0;
    }
    global = importantKeys.isEmpty ? 0.0 : global / importantKeys.length;

    return OcrValidationResult(
      normalizedData: normalized,
      warnings: warnings,
      confidence: confidence,
      globalConfidence: global,
    );
  }
}
