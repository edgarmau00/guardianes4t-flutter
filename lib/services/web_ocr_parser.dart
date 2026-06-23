import 'package:flutter/foundation.dart';

import 'cp_service.dart';

class WebOcrParser {
  static final RegExp _claveElectorExactRegex = RegExp(
    r'^(?:[A-Z]{6}[0-9]{6}[0-9]{2}[HM][0-9]{3}|[A-Z]{5}[0-9]{6}[0-9]{2}[HM][0-9]{4})$',
  );
  static final RegExp _claveElectorLooseRegex = RegExp(
    r'(?:[A-Z]{6}[0-9OILSZBQ]{6}[0-9OILSZBQ]{2}[HMN][0-9OILSZBQ]{3}|[A-Z]{5}[0-9OILSZBQ]{6}[0-9OILSZBQ]{2}[HMN][0-9OILSZBQ]{4})',
  );
  static final RegExp _curpExactRegex = RegExp(
    r'^[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}$',
  );
  static final RegExp _curpLooseRegex = RegExp(
    r'[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}',
  );

  static const List<String> _states = [
    'AGUASCALIENTES',
    'BAJA CALIFORNIA',
    'BAJA CALIFORNIA SUR',
    'CAMPECHE',
    'CHIAPAS',
    'CHIHUAHUA',
    'CIUDAD DE MEXICO',
    'COAHUILA',
    'COAHUILA DE ZARAGOZA',
    'COLIMA',
    'DURANGO',
    'GUANAJUATO',
    'GUERRERO',
    'HIDALGO',
    'JALISCO',
    'MEXICO',
    'MICHOACAN',
    'MICHOACAN DE OCAMPO',
    'MORELOS',
    'NAYARIT',
    'NUEVO LEON',
    'OAXACA',
    'PUEBLA',
    'QUERETARO',
    'QUINTANA ROO',
    'SAN LUIS POTOSI',
    'SINALOA',
    'SONORA',
    'TABASCO',
    'TAMAULIPAS',
    'TLAXCALA',
    'VERACRUZ',
    'VERACRUZ DE IGNACIO DE LA LLAVE',
    'YUCATAN',
    'ZACATECAS',
  ];

  static const List<String> _knownMunicipios = [
    'GUADALAJARA',
    'ZAPOPAN',
    'TLAJOMULCO',
    'TONALA',
    'TLAQUEPAQUE',
    'MORELIA',
    'URUAPAN',
    'LEON',
    'IRAPUATO',
    'CELAYA',
    'MONTERREY',
    'GUADALUPE',
    'SAN NICOLAS',
    'PUEBLA',
    'VERACRUZ',
    'XALAPA',
    'BOCA DEL RIO',
    'MERIDA',
    'CANCUN',
    'QUERETARO',
    'TOLUCA',
    'ECATEPEC',
    'NAUCALPAN',
    'NEZAHUALCOYOTL',
    'ZUMPANGO',
    'TECAMAC',
    'CUAUTITLAN',
    'TULTITLAN',
    'IZTAPALAPA',
    'COYOACAN',
  ];

  Future<Map<String, String>> parse(String rawText) async {
    final normalized = _normalize(rawText);
    final lines = _cleanLines(normalized);

    final claveElectoral = _extractClaveElectoral(normalized, lines);
    final curp = _extractCurp(normalized, lines);
    final fechaNacimiento = _extractFechaNacimiento(normalized, lines);
    final vigencia = _extractVigencia(normalized, lines);
    final seccion = _extractSeccion(normalized, lines);
    final sexo = _extractSexo(normalized, lines);
    final codigoPostal = _extractCodigoPostal(normalized, lines);
    final nameParts = _extractNameParts(lines, normalized);
    final addressParts = await _extractAddressParts(lines, normalized, codigoPostal);
    final direccion = _sanitizeAddressWithName(
      addressParts['direccion'] ?? '',
      nameParts,
    );

    return {
      'rawText': normalized,
      'processingMode': (addressParts['catalogMatched'] ?? '') == '1'
          ? 'web_tesseract_cp'
          : 'web_tesseract',
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
      'estado': addressParts['estado'] ?? '',
      'municipio': addressParts['municipio'] ?? '',
    };
  }

  String _normalize(String text) {
    var value = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAllMapped(RegExp(r'[ \t]+'), (_) => ' ')
        .trim()
        .toUpperCase();

    const replacements = {
      'Ã': 'A',
      'Ã‰': 'E',
      'Ã': 'I',
      'Ã“': 'O',
      'Ãš': 'U',
      'Ãœ': 'U',
      'Ã‘': 'N',
      'Ãƒâ€œ': 'O',
      'Ãƒâ€°': 'E',
      'ÃƒÂ': 'I',
      'ÃƒÂ': 'A',
      'ÃƒÅ¡': 'U',
      'SECCI0N': 'SECCION',
      'SECCI6N': 'SECCION',
      'SECCIQN': 'SECCION',
      'D0MICILI0': 'DOMICILIO',
      'D0M1C1L10': 'DOMICILIO',
      'CURP.': 'CURP',
      'CLAVE DE ELECT0R': 'CLAVE DE ELECTOR',
      'N0MBRE': 'NOMBRE',
    };

    replacements.forEach((from, to) {
      value = value.replaceAll(from, to);
    });

    return value;
  }

  List<String> _cleanLines(String text) {
    return text
        .split('\n')
        .map((line) => _normalizeHumanText(line))
        .where((line) => line.isNotEmpty)
        .toList();
  }

  String _extractClaveElectoral(String text, List<String> lines) {
    for (final candidate in [
      _extractCompactTokenAfterLabel(
        lines,
        'CLAVE DE ELECTOR',
        minLength: 17,
        maxLength: 19,
      ),
      _extractCompactTokenAfterLabel(
        lines,
        'CLAVE',
        minLength: 17,
        maxLength: 19,
      ),
    ]) {
      final fixed = _fixClaveElector(candidate);
      if (_claveElectorExactRegex.hasMatch(fixed)) return fixed;
    }

    final compact = _compactAlphaNumeric(text);
    for (final match in _claveElectorLooseRegex.allMatches(compact)) {
      final fixed = _fixClaveElector(match.group(0) ?? '');
      if (_claveElectorExactRegex.hasMatch(fixed)) return fixed;
    }

    return '';
  }

  String _extractCurp(String text, List<String> lines) {
    final labeled = _extractCompactTokenAfterLabel(
      lines,
      'CURP',
      minLength: 18,
      maxLength: 20,
    );
    final fixedLabeled = _fixCurp(labeled);
    if (_curpExactRegex.hasMatch(fixedLabeled)) return fixedLabeled;

    final compact = _compactAlphaNumeric(text);
    for (final match in _curpLooseRegex.allMatches(compact)) {
      final fixed = _fixCurp(match.group(0) ?? '');
      if (_curpExactRegex.hasMatch(fixed)) return fixed;
    }

    return '';
  }

  String _extractFechaNacimiento(String text, List<String> lines) {
    final labeled = _extractValueNearLabel(lines, 'FECHA DE NACIMIENTO');
    final fixedLabeled = _fixFecha(labeled);
    if (_isFecha(fixedLabeled)) return fixedLabeled;

    final match = RegExp(r'\b\d{2}[\/\-.]\d{2}[\/\-.]\d{4}\b').firstMatch(text);
    final fixed = _fixFecha(match?.group(0) ?? '');
    return _isFecha(fixed) ? fixed : '';
  }

  String _extractVigencia(String text, List<String> lines) {
    final labeled = _extractCompactTokenAfterLabel(
      lines,
      'VIGENCIA',
      minLength: 8,
      maxLength: 10,
      allowDash: true,
    );
    final fixedLabeled = _fixVigencia(labeled);
    if (_isVigencia(fixedLabeled)) return fixedLabeled;

    final match = RegExp(r'\b\d{4}\s*[-\/]\s*\d{4}\b').firstMatch(text);
    final fixed = _fixVigencia(match?.group(0) ?? '');
    return _isVigencia(fixed) ? fixed : '';
  }

  String _extractSeccion(String text, List<String> lines) {
    final labeled = _extractCompactTokenAfterLabel(
      lines,
      'SECCION',
      minLength: 3,
      maxLength: 4,
    );
    final fixedLabeled = _fixSeccion(labeled);
    if (fixedLabeled.length >= 3 && fixedLabeled.length <= 4) {
      return fixedLabeled;
    }

    final direct = RegExp(r'SECCION[:\s]*([0-9OILSZBQ]{3,4})')
        .firstMatch(text.replaceAll('\n', ' '));
    if (direct != null) {
      final fixed = _fixSeccion(direct.group(1) ?? '');
      if (fixed.length >= 3 && fixed.length <= 4) return fixed;
    }

    return '';
  }

  String _extractSexo(String text, List<String> lines) {
    if (text.contains('MUJER')) return 'M';
    if (text.contains('HOMBRE')) return 'H';

    final labeled = _extractValueNearLabel(lines, 'SEXO');
    final fixed = _fixSexo(labeled);
    if (fixed == 'H' || fixed == 'M') return fixed;

    final compact = text.replaceAll(RegExp(r'[^A-Z]'), ' ');
    final match = RegExp(r'\b([HM])\b').firstMatch(compact);
    return match?.group(1) ?? '';
  }

  String _extractCodigoPostal(String text, List<String> lines) {
    final domicilioLines = _extractLinesAfterLabel(
      lines,
      'DOMICILIO',
      stopLabels: const [
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
      ],
      maxLines: 4,
    );

    for (final line in domicilioLines) {
      final match = RegExp(r'\b\d{5}\b').firstMatch(_fixCommonNumericOcr(line));
      if (match != null) return match.group(0) ?? '';
    }

    final all = RegExp(r'\b\d{5}\b')
        .allMatches(_fixCommonNumericOcr(text))
        .toList();
    return all.isEmpty ? '' : (all.last.group(0) ?? '');
  }

  Future<Map<String, String>> _extractAddressParts(
    List<String> lines,
    String fullText,
    String codigoPostal,
  ) async {
    final addressLines = _extractAddressLines(lines, fullText);

    var direccion = '';
    var municipio = '';
    var estado = '';

    if (addressLines.isNotEmpty) {
      final municipioEstado = _extractMunicipioEstadoFromLines(addressLines);
      municipio = municipioEstado['municipio'] ?? '';
      estado = municipioEstado['estado'] ?? '';

      final addressCandidates = addressLines.where((line) {
        final clean = _cleanupDireccionFinal(line);
        if (clean.isEmpty) return false;
        if (_containsForbiddenAddressContent(clean)) return false;
        if (!_looksUsefulAddress(clean)) return false;
        if (municipio.isNotEmpty &&
            _normalizeForCompare(clean) == _normalizeForCompare(municipio)) {
          return false;
        }
        if (estado.isNotEmpty &&
            _normalizeForCompare(clean) == _normalizeForCompare(estado)) {
          return false;
        }
        return true;
      }).toList();

      if (addressCandidates.isNotEmpty) {
        direccion = _buildDireccionFromLines(
          addressCandidates,
          municipio: municipio,
          estado: estado,
        );
      }
    }

    final cpData = await _lookupCpData(codigoPostal);
    final estadoFinal = _preferCatalogValue(
      catalogValue: cpData?['estado'],
      ocrValue: estado,
    );
    final municipioFinal = _preferCatalogValue(
      catalogValue: cpData?['municipio'],
      ocrValue: municipio,
    );

    return {
      'direccion': direccion,
      'estado': estadoFinal,
      'municipio': municipioFinal,
      'catalogMatched': cpData != null ? '1' : '0',
    };
  }

  List<String> _extractAddressLines(List<String> lines, String fullText) {
    final domicilioLines = _extractLinesAfterLabel(
      lines,
      'DOMICILIO',
      stopLabels: const [
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
        'ANO DE REGISTRO',
      ],
      maxLines: 4,
    );

    if (domicilioLines.isNotEmpty) {
      return domicilioLines;
    }

    return lines.where((line) {
      final upper = line.toUpperCase();
      return upper.contains('CALLE') ||
          upper.contains('AV') ||
          upper.contains('COL') ||
          upper.contains('MANZANA') ||
          upper.contains('LOTE') ||
          upper.contains('NUM') ||
          upper.contains('PRIV') ||
          RegExp(r'\d').hasMatch(upper);
    }).take(4).toList();
  }

  Map<String, String> _extractNameParts(List<String> lines, String fullText) {
    final labeledFull = _extractLinesAfterLabel(
      lines,
      'NOMBRE',
      stopLabels: const ['DOMICILIO', 'SEXO', 'CLAVE DE ELECTOR'],
      maxLines: 4,
    );

    final labeledZone = _extractNameLines(lines);
    final candidates = <String>[];
    final seen = <String>{};

    for (final line in [...labeledFull, ...labeledZone]) {
      final clean = _cleanupNameValue(line);
      final normalized = _normalizeForCompare(clean);
      if (clean.isEmpty || normalized.isEmpty || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      candidates.add(clean);
    }

    if (candidates.isEmpty) {
      return const {
        'nombre': '',
        'apellidoPaterno': '',
        'apellidoMaterno': '',
      };
    }

    if (candidates.length >= 3) {
      return {
        'apellidoPaterno': _cleanupNameValue(candidates[0]),
        'apellidoMaterno': _cleanupNameValue(candidates[1]),
        'nombre': _cleanupNameValue(candidates.sublist(2).join(' ')),
      };
    }

    if (candidates.length == 2) {
      return {
        'apellidoPaterno': _cleanupNameValue(candidates[0]),
        'apellidoMaterno': '',
        'nombre': _cleanupNameValue(candidates[1]),
      };
    }

    final merged = _normalizeHumanText(candidates.join(' '));
    final parts = merged
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (parts.length >= 3) {
      final apellidoMaterno = parts.removeLast();
      final apellidoPaterno = parts.removeLast();
      final nombre = parts.join(' ');

      return {
        'nombre': _cleanupNameValue(nombre),
        'apellidoPaterno': _cleanupNameValue(apellidoPaterno),
        'apellidoMaterno': _cleanupNameValue(apellidoMaterno),
      };
    }

    return {
      'nombre': _cleanupNameValue(merged),
      'apellidoPaterno': '',
      'apellidoMaterno': '',
    };
  }

  List<String> _extractNameLines(List<String> lines) {
    return lines.where((line) {
      if (_normalizeForCompare(line) == 'NOMBRE') return false;
      if (_looksLikeLabel(line)) return false;
      if (_looksLikeHeaderNoise(line)) return false;
      if (_looksLikeForeignDataLine(line)) return false;
      if (RegExp(r'^\d+$').hasMatch(_normalizeForCompare(line))) return false;
      if (RegExp(r'^\d{5}$').hasMatch(_normalizeForCompare(line))) return false;
      return true;
    }).toList();
  }

  Map<String, String> _extractMunicipioEstadoFromLines(List<String> lines) {
    for (var i = lines.length - 1; i >= 0; i--) {
      final parsed = _parseMunicipioEstado(lines[i]);
      final municipio = (parsed['municipio'] ?? '').trim();
      final estado = (parsed['estado'] ?? '').trim();

      if (municipio.isNotEmpty || estado.isNotEmpty) {
        return {
          'municipio': municipio,
          'estado': estado,
        };
      }
    }

    return const {
      'municipio': '',
      'estado': '',
    };
  }

  Map<String, String> _parseMunicipioEstado(String line) {
    final clean = _normalizeHumanText(line);
    if (clean.isEmpty) {
      return const {
        'municipio': '',
        'estado': '',
      };
    }

    if (_looksLikeForeignDataLine(clean) ||
        _containsForbiddenAddressContent(clean)) {
      return const {
        'municipio': '',
        'estado': '',
      };
    }

    final upper = _normalizeForCompare(clean);

    for (final state in _states) {
      final stateNorm = _normalizeForCompare(state);
      if (upper.endsWith(', $stateNorm') ||
          upper.endsWith(',$stateNorm') ||
          upper.endsWith(' $stateNorm') ||
          upper == stateNorm) {
        final idx = upper.lastIndexOf(stateNorm);
        var municipio = clean.substring(0, idx).trim();
        municipio = municipio.replaceAll(RegExp(r'[,\s]+$'), '').trim();
        return {
          'municipio': municipio,
          'estado': state,
        };
      }
    }

    if (upper.endsWith(', MEX.') ||
        upper.endsWith(', MEX') ||
        upper.endsWith(' MEX.') ||
        upper.endsWith(' MEX')) {
      final idx = upper.lastIndexOf('MEX');
      var municipio = clean.substring(0, idx).trim();
      municipio = municipio.replaceAll(RegExp(r'[,\s]+$'), '').trim();
      return {
        'municipio': municipio,
        'estado': 'MEXICO',
      };
    }

    return const {
      'municipio': '',
      'estado': '',
    };
  }

  bool _looksUsefulAddress(String value) {
    final text = _normalizeHumanText(value);
    if (text.isEmpty) return false;
    if (text.length < 5) return false;

    final normalized = _normalizeForCompare(text);
    final words = text.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();

    final hasStreetHint = RegExp(
      r'\b(CALLE|CALZ|CALLEJON|AV|AVENIDA|ANDADOR|CDA|CERRADA|PRIV|PRIVADA|MZ|MANZANA|LT|LOTE|NUM|NO|N\.|#)\b',
    ).hasMatch(normalized);
    final hasDigits = RegExp(r'\d').hasMatch(normalized);

    if (!hasStreetHint && !hasDigits && text.length < 8) {
      return false;
    }

    if (!hasStreetHint &&
        !hasDigits &&
        RegExp(r'^[A-Z\s]+$').hasMatch(normalized) &&
        words.length >= 2 &&
        words.length <= 5) {
      return false;
    }

    if (RegExp(r'^[A-Z\s]+$').hasMatch(normalized) && words.length <= 2) {
      return false;
    }

    if (_looksLikeForeignDataLine(text)) return false;
    if (_containsForbiddenAddressContent(text)) return false;
    if (RegExp(r'^\d+$').hasMatch(_normalizeForCompare(text))) return false;

    return true;
  }

  String _cleanupDireccionFinal(String value) {
    var text = _normalizeHumanText(value);
    if (text.isEmpty) return '';

    text = text.replaceAll(
      RegExp(r'D[O0]M[I1L][C0O][I1L][I1L][O0QK]', caseSensitive: false),
      ' ',
    );
    text = text.replaceAll(
      RegExp(r'D[O0]M[I1L]C[I1L][I1L][O0QK]', caseSensitive: false),
      ' ',
    );

    for (final token in const [
      'DOMICILIO',
      'DIRECCION',
      'CURP',
      'CLAVE DE ELECTOR',
      'SECCION',
      'VIGENCIA',
      'SEXO',
      'FECHA DE NACIMIENTO',
    ]) {
      text = text.replaceAll(RegExp('\\b$token\\b', caseSensitive: false), ' ');
    }

    text = text
        .replaceAll(RegExp(r'EMISION.*$', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'A[NÑ]O\s+DE\s+REGISTRO.*$', caseSensitive: false), ' ')
        .replaceAll(
          RegExp(r'\b[A-Z]{6}[0-9OILSZBQ]{6}[A-Z][0-9OILSZBQ]{3}\b'),
          ' ',
        )
        .replaceAll(
          RegExp(r'\b[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}\b'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    text = _dedupeRepeatedAddressPhrase(text);
    text = text.replaceAll(RegExp(r'^[,\-:\s]+'), '').trim();

    if (_containsForbiddenAddressContent(text)) return '';
    return text;
  }

  String _cleanupNameValue(String value) {
    var text = _normalizeHumanText(value);
    if (text.isEmpty) return '';

    text = text
        .replaceAll(RegExp(r'\bNOMBRE\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bNOMBFE\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bNOMBRE[S]?\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bDOMICILIO\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bDIRECCION\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return text;
  }

  String _buildDireccionFromLines(
    List<String> lines, {
    required String municipio,
    required String estado,
  }) {
    final cleanedLines = <String>[];

    for (final line in lines) {
      var clean = _cleanupDireccionFinal(line);
      if (clean.isEmpty) continue;

      if (municipio.isNotEmpty &&
          _normalizeForCompare(clean) == _normalizeForCompare(municipio)) {
        continue;
      }
      if (estado.isNotEmpty &&
          _normalizeForCompare(clean) == _normalizeForCompare(estado)) {
        continue;
      }

      final municipioEstado = _parseMunicipioEstado(clean);
      if ((municipioEstado['municipio'] ?? '').isNotEmpty ||
          (municipioEstado['estado'] ?? '').isNotEmpty) {
        continue;
      }

      clean = clean.replaceAll(RegExp(r'\b\d{5}\b'), '').trim();
      clean = _normalizeHumanText(clean);
      if (clean.isEmpty) continue;

      cleanedLines.add(clean);
      if (cleanedLines.length >= 2) break;
    }

    return _joinUniqueNormalized(cleanedLines);
  }

  String _sanitizeAddressWithName(
    String direccion,
    Map<String, String> nameParts,
  ) {
    var text = _cleanupDireccionFinal(direccion);
    if (text.isEmpty) return '';

    final nameTokens = [
      nameParts['nombre'] ?? '',
      nameParts['apellidoPaterno'] ?? '',
      nameParts['apellidoMaterno'] ?? '',
    ]
        .map(_normalizeForCompare)
        .expand((value) => value.split(RegExp(r'\s+')))
        .map((token) => token.trim())
        .where((token) => token.length >= 3)
        .toSet();

    if (nameTokens.isNotEmpty) {
      final filteredWords = <String>[];
      final words = text.split(RegExp(r'\s+'));
      var i = 0;

      while (i < words.length) {
        final currentNorm = _normalizeForCompare(words[i]);
        if (!nameTokens.contains(currentNorm)) {
          filteredWords.add(words[i]);
          i++;
          continue;
        }

        var j = i;
        while (j < words.length &&
            nameTokens.contains(_normalizeForCompare(words[j]))) {
          j++;
        }

        final runLength = j - i;
        if (runLength < 2) {
          filteredWords.add(words[i]);
        }
        i = j;
      }

      text = _normalizeHumanText(filteredWords.join(' '));
    }

    text = _dedupeRepeatedAddressPhrase(text);
    text = _cleanupDireccionFinal(text);
    return text;
  }

  String _dedupeRepeatedAddressPhrase(String value) {
    final words = value
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (words.length < 4) return _normalizeHumanText(value);

    for (var size = words.length ~/ 2; size >= 2; size--) {
      final first = words.sublist(0, size);
      final second = words.sublist(size, size * 2);
      if (listEquals(first, second)) {
        return _normalizeHumanText(first.join(' '));
      }
    }

    for (var start = 0; start < words.length; start++) {
      for (var size = 2; start + (size * 2) <= words.length; size++) {
        final first = words.sublist(start, start + size);
        final second = words.sublist(start + size, start + (size * 2));
        if (listEquals(first, second)) {
          final collapsed = <String>[
            ...words.sublist(0, start),
            ...first,
            ...words.sublist(start + (size * 2)),
          ];
          return _normalizeHumanText(collapsed.join(' '));
        }
      }
    }

    return _normalizeHumanText(value);
  }

  String _joinUniqueNormalized(List<String> values) {
    final unique = <String>[];
    final seen = <String>{};

    for (final value in values) {
      final cleaned = _cleanupDireccionFinal(value);
      final normalized = _normalizeForCompare(cleaned);
      if (cleaned.isEmpty || normalized.isEmpty || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      unique.add(cleaned);
    }

    return unique.join(' ');
  }

  Future<Map<String, String>?> _lookupCpData(String codigoPostal) async {
    final cp = _fixCodigoPostal(codigoPostal);
    if (cp.length != 5) return null;

    try {
      if (!CpService.isLoaded) {
        await CpService.load();
      }
      final data = CpService.getDataByCp(cp);
      if (data == null) return null;

      final estado = _normalizeHumanText(data['estado'] ?? '');
      final municipio = _normalizeHumanText(data['municipio'] ?? '');
      if (estado.isEmpty && municipio.isEmpty) return null;

      return {
        'estado': estado,
        'municipio': municipio,
      };
    } catch (_) {
      return null;
    }
  }

  String _preferCatalogValue({
    required String? catalogValue,
    required String? ocrValue,
  }) {
    final catalog = _normalizeHumanText(catalogValue ?? '');
    final ocr = _normalizeHumanText(ocrValue ?? '');
    if (catalog.isNotEmpty) return catalog;
    return ocr;
  }

  List<String> _extractLinesAfterLabel(
    List<String> lines,
    String label, {
    required List<String> stopLabels,
    int maxLines = 2,
  }) {
    final out = <String>[];
    final labelNorm = _normalizeHumanText(label);
    final stopNorms = stopLabels.map(_normalizeHumanText).toList();

    var collecting = false;
    for (final rawLine in lines) {
      final line = _normalizeHumanText(rawLine);
      if (!collecting) {
        if (line == labelNorm ||
            line.startsWith('$labelNorm ') ||
            line.contains(labelNorm)) {
          collecting = true;
          final inline = _normalizeHumanText(
            line.replaceFirst(labelNorm, '').replaceAll(':', ' '),
          );
          if (inline.isNotEmpty && !_looksLikeLabel(inline)) {
            out.add(inline);
          }
          continue;
        }
      } else {
        if (stopNorms.any((stop) => line == stop || line.startsWith('$stop '))) {
          break;
        }
        if (!_looksLikeLabel(line) && line.isNotEmpty) {
          out.add(line);
        }
        if (out.length >= maxLines) break;
      }
    }
    return out;
  }

  String _extractValueNearLabel(List<String> lines, String label) {
    final values = _extractLinesAfterLabel(
      lines,
      label,
      stopLabels: const [
        'NOMBRE',
        'DOMICILIO',
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
      ],
      maxLines: 2,
    );
    return values.join(' ');
  }

  String _extractCompactTokenAfterLabel(
    List<String> lines,
    String label, {
    required int minLength,
    required int maxLength,
    bool allowDash = false,
  }) {
    final values = _extractLinesAfterLabel(
      lines,
      label,
      stopLabels: const [
        'NOMBRE',
        'DOMICILIO',
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
      ],
      maxLines: 2,
    );

    for (final value in values) {
      final cleaned = allowDash
          ? value.replaceAll(RegExp(r'[^A-Z0-9-]'), '')
          : value.replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (cleaned.length >= minLength && cleaned.length <= maxLength) {
        return cleaned;
      }
    }

    return '';
  }

  bool _looksLikePersonName(String value) {
    if (value.isEmpty) return false;
    if (RegExp(r'\d').hasMatch(value)) return false;
    if (_looksLikeLabel(value)) return false;

    final words = value.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    if (words.length < 2 || words.length > 5) return false;
    if (words.any((word) => word.length < 2)) return false;
    return true;
  }

  bool _looksLikeLabel(String value) {
    const labels = [
      'NOMBRE',
      'DOMICILIO',
      'CURP',
      'SEXO',
      'SECCION',
      'VIGENCIA',
      'FECHA DE NACIMIENTO',
      'CLAVE DE ELECTOR',
      'ANO DE REGISTRO',
    ];
    final normalized = _normalizeHumanText(value);
    return labels.any((label) => normalized == label);
  }

  bool _looksLikeHeaderNoise(String value) {
    final normalized = _normalizeForCompare(value);
    return normalized.contains('INSTITUTO') ||
        normalized.contains('NACIONAL') ||
        normalized.contains('ELECTORAL') ||
        normalized.contains('ESTADOSUNIDOSMEXICANOS');
  }

  bool _looksLikeForeignDataLine(String value) {
    final normalized = _normalizeForCompare(value);
    return normalized.contains('CURP') ||
        normalized.contains('CLAVEELECTOR') ||
        normalized.contains('FECHANACIMIENTO') ||
        normalized.contains('SEXO') ||
        normalized.contains('VIGENCIA') ||
        normalized.contains('SECCION');
  }

  bool _containsForbiddenAddressContent(String value) {
    final normalized = _normalizeForCompare(value);
    return normalized.contains('CURP') ||
        normalized.contains('CLAVEELECTOR') ||
        normalized.contains('FECHANACIMIENTO') ||
        normalized.contains('SEXO') ||
        normalized.contains('VIGENCIA');
  }

  String _normalizeHumanText(String value) {
    return value
        .replaceAllMapped(RegExp(r'\s+'), (_) => ' ')
        .replaceAll(RegExp(r'[:;]+'), ' ')
        .trim();
  }

  String _normalizeForCompare(String value) {
    return _normalizeHumanText(value)
        .replaceAll(RegExp(r'[^A-Z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _compactAlphaNumeric(String value) {
    return _normalizeHumanText(value).replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  String _fixCommonNumericOcr(String value) {
    return value
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('S', '5')
        .replaceAll('Z', '2')
        .replaceAll('B', '8')
        .replaceAll('Q', '0');
  }

  String _fixClaveElector(String value) {
    return _fixCommonNumericOcr(value)
        .replaceAll(RegExp(r'[^A-Z0-9]'), '')
        .replaceFirstMapped(RegExp(r'^([A-Z]{5,6})'), (m) => m.group(1) ?? '')
        .replaceFirst('N', 'H');
  }

  String _fixCurp(String value) {
    final cleaned =
        _fixCommonNumericOcr(value).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (cleaned.length < 18) return cleaned;

    final buffer = StringBuffer();
    for (var i = 0; i < cleaned.length && i < 18; i++) {
      var ch = cleaned[i];
      if (i < 4 || (i >= 11 && i <= 15)) {
        ch = ch.replaceAll(RegExp(r'[0-9]'), '');
      } else if ((i >= 4 && i <= 9) || i >= 16) {
        ch = _fixCommonNumericOcr(ch);
      }
      if (i == 10 && ch == 'N') ch = 'H';
      buffer.write(ch);
    }
    return buffer.toString();
  }

  String _fixFecha(String value) {
    final cleaned =
        _fixCommonNumericOcr(value).replaceAll(RegExp(r'[^0-9/.-]'), '');
    final match =
        RegExp(r'(\d{2})[\/\-.](\d{2})[\/\-.](\d{4})').firstMatch(cleaned);
    if (match == null) return '';
    return '${match.group(1)}/${match.group(2)}/${match.group(3)}';
  }

  String _fixVigencia(String value) {
    final cleaned = _fixCommonNumericOcr(value).replaceAll(RegExp(r'[^0-9/-]'), '');
    final match = RegExp(r'(\d{4})[/-](\d{4})').firstMatch(cleaned);
    if (match == null) return '';
    return '${match.group(1)}-${match.group(2)}';
  }

  String _fixSeccion(String value) {
    return _fixCommonNumericOcr(value).replaceAll(RegExp(r'[^0-9]'), '');
  }

  String _fixSexo(String value) {
    final normalized = _normalizeHumanText(value);
    if (normalized.contains('MUJER')) return 'M';
    if (normalized.contains('HOMBRE')) return 'H';
    if (normalized == 'M' || normalized == 'H') return normalized;
    return '';
  }

  String _fixCodigoPostal(String value) {
    return _fixCommonNumericOcr(value).replaceAll(RegExp(r'[^0-9]'), '');
  }

  bool _isFecha(String value) => RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(value);

  bool _isVigencia(String value) => RegExp(r'^\d{4}-\d{4}$').hasMatch(value);
}
