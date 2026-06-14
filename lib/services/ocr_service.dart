import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;

import 'ine_detector_service.dart';
import 'ocr_validation_service.dart';

class OcrService {
  static const int _maxOcrWidth = 1280;
  final TextRecognizer _recognizer = TextRecognizer();
  final IneDetectorService _detector = IneDetectorService();
  final Map<String, Future<RecognizedText?>> _recognizedTextCache = {};
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

  static List<Map<String, dynamic>>? _cpCatalogCache;

  static const List<String> _mexicanStates = [
    'AGUASCALIENTES',
    'BAJA CALIFORNIA',
    'BAJA CALIFORNIA SUR',
    'CAMPECHE',
    'CHIAPAS',
    'CHIHUAHUA',
    'CIUDAD DE MEXICO',
    'CIUDAD DE MÉXICO',
    'COAHUILA',
    'COAHUILA DE ZARAGOZA',
    'COLIMA',
    'DURANGO',
    'GUANAJUATO',
    'GUERRERO',
    'HIDALGO',
    'JALISCO',
    'MEXICO',
    'MÉXICO',
    'MICHOACAN',
    'MICHOACÁN',
    'MICHOACAN DE OCAMPO',
    'MORELOS',
    'NAYARIT',
    'NUEVO LEON',
    'NUEVO LEÓN',
    'OAXACA',
    'PUEBLA',
    'QUERETARO',
    'QUERÉTARO',
    'QUINTANA ROO',
    'SAN LUIS POTOSI',
    'SAN LUIS POTOSÍ',
    'SINALOA',
    'SONORA',
    'TABASCO',
    'TAMAULIPAS',
    'TLAXCALA',
    'VERACRUZ',
    'VERACRUZ DE IGNACIO DE LA LLAVE',
    'YUCATAN',
    'YUCATÁN',
    'ZACATECAS',
  ];

  Future<Map<String, String>> scanIne(String imagePath) async {
    final primary = await _scanIneSingle(imagePath);
    final primaryValidation = OcrValidationService().validate(primary);

    if (!_needsRescuePass(primaryValidation)) {
      return _enforceStrictFieldAcceptance(primaryValidation);
    }

    debugPrint('[OCR] Activando rescue pass para mejorar precision');

    final rescuePaths = await _prepareRescueImageVariants(imagePath);
    if (rescuePaths.isEmpty) {
      return primary;
    }

    OcrValidationResult bestValidation = primaryValidation;

    for (final rescuePath in rescuePaths) {
      final candidate = await _scanIneSingle(rescuePath);
      final candidateValidation = OcrValidationService().validate(candidate);

      if (_isBetterValidation(candidateValidation, bestValidation)) {
        bestValidation = candidateValidation;
      }
    }

    return _enforceStrictFieldAcceptance(bestValidation);
  }

  Future<Map<String, String>> _scanIneSingle(String imagePath) async {
    debugPrint('[OCR] scanIne() -> iniciando con imagen: $imagePath');

    final detected = await _detector.detectAndCrop(imagePath);
    final hasDetectedZones = detected.cropsByLabel.isNotEmpty;

    debugPrint(
      '[OCR] detectAndCrop() terminado | detecciones=${detected.detections.length} | crops=${detected.cropsByLabel.keys.join(', ')}',
    );

    Map<String, String>? modelResult;

    if (hasDetectedZones) {
      debugPrint('[OCR] USANDO MODELO (detected zones)');
      modelResult = await _scanUsingDetectedZones(
        imagePath: imagePath,
        cropsByLabel: detected.cropsByLabel,
      );

      if (_shouldTrustModelResult(modelResult)) {
        return modelResult;
      }

      if (_isGoodEnoughModelResult(modelResult)) {
        debugPrint('[OCR] Modelo suficiente, se evita fallback pesado');
        return modelResult;
      }
    }

    debugPrint('[OCR] USANDO FALLBACK (fixed zones)');
    final fallbackResult = await _scanUsingFixedZones(imagePath);

    if (modelResult == null) {
      return fallbackResult;
    }

    return _mergeScanResults(
      primary: modelResult,
      secondary: fallbackResult,
    );
  }

  bool _needsRescuePass(OcrValidationResult validation) {
    final claveScore = validation.confidence['claveElectoral'] ?? 0.0;
    final curpScore = validation.confidence['curp'] ?? 0.0;
    final direccionScore = validation.confidence['direccion'] ?? 0.0;
    final nombreScore = validation.confidence['nombre'] ?? 0.0;
    final normalized = validation.normalizedData;
    final clave = (normalized['claveElectoral'] ?? '').trim();
    final curp = (normalized['curp'] ?? '').trim();
    final direccion = (normalized['direccion'] ?? '').trim();
    final criticalMissingCount = [
      clave.isEmpty,
      curp.isEmpty,
      direccion.isEmpty,
    ].where((missing) => missing).length;

    if (criticalMissingCount >= 2) return true;
    if (criticalMissingCount >= 1 && validation.globalConfidence < 0.60) {
      return true;
    }
    if (claveScore < 0.45 && curpScore < 0.45) return true;
    if (direccionScore < 0.25 && nombreScore < 0.40) return true;
    return false;
  }

  bool _isBetterValidation(
    OcrValidationResult candidate,
    OcrValidationResult current,
  ) {
    double score(OcrValidationResult validation) {
      return validation.globalConfidence * 10 +
          (validation.confidence['claveElectoral'] ?? 0.0) * 4 +
          (validation.confidence['curp'] ?? 0.0) * 4 +
          (validation.confidence['direccion'] ?? 0.0) * 3 +
          (validation.confidence['nombre'] ?? 0.0) * 2 +
          (validation.confidence['apellidoPaterno'] ?? 0.0) * 2 +
          (validation.confidence['fechaNacimiento'] ?? 0.0) * 2 +
          (validation.confidence['vigencia'] ?? 0.0) * 2 +
          (validation.confidence['sexo'] ?? 0.0) * 1.5 +
          (validation.confidence['seccionElectoral'] ?? 0.0) * 2;
    }

    return score(candidate) > score(current);
  }

  Map<String, String> _enforceStrictFieldAcceptance(
    OcrValidationResult validation,
  ) {
    final result = _sanitizeResultByField(
      Map<String, String>.from(validation.normalizedData),
    );

    final thresholds = <String, double>{
      'claveElectoral': 0.95,
      'curp': 0.95,
      'fechaNacimiento': 0.90,
      'vigencia': 0.90,
      'seccionElectoral': 0.90,
      'sexo': 0.90,
      'codigoPostal': 0.90,
      'direccion': 0.75,
      'nombre': 0.75,
      'apellidoPaterno': 0.75,
      'apellidoMaterno': 0.65,
      'municipio': 0.75,
      'estado': 0.75,
    };

    final exactFields = <String, bool Function(String value)>{
      'claveElectoral': (value) =>
          _claveElectorExactRegex.hasMatch(_fixClaveElector(value)),
      'curp': (value) => _curpExactRegex.hasMatch(_fixCurp(value)),
      'fechaNacimiento': (value) =>
          RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(_fixFecha(value)),
      'vigencia': (value) =>
          RegExp(r'^\d{4}-\d{4}$').hasMatch(_fixVigencia(value)),
      'seccionElectoral': (value) =>
          RegExp(r'^\d{3,4}$').hasMatch(_fixSeccion(value)),
      'sexo': (value) {
        final fixed = _fixSexo(value);
        return fixed == 'H' || fixed == 'M';
      },
      'codigoPostal': (value) =>
          RegExp(r'^\d{5}$').hasMatch(_fixCodigoPostal(value)),
    };

    for (final entry in thresholds.entries) {
      final value = (result[entry.key] ?? '').trim();
      if (value.isEmpty) continue;

      final exactValidator = exactFields[entry.key];
      if (exactValidator != null && exactValidator(value)) {
        continue;
      }

      final score = validation.confidence[entry.key] ?? 0.0;
      if (score < entry.value) {
        result[entry.key] = '';
      }
    }

    result['claveElector'] = result['claveElectoral'] ?? '';
    result['seccion'] = result['seccionElectoral'] ?? '';

    return result;
  }

  Map<String, String> _sanitizeResultByField(Map<String, String> data) {
    final result = Map<String, String>.from(data);

    result['nombre'] = _sanitizeNameLikeField(result['nombre'] ?? '');
    result['apellidoPaterno'] = _sanitizeNameLikeField(
      result['apellidoPaterno'] ?? '',
    );
    result['apellidoMaterno'] = _sanitizeNameLikeField(
      result['apellidoMaterno'] ?? '',
    );
    result['direccion'] = _sanitizeAddressField(result['direccion'] ?? '');
    result['municipio'] = _sanitizePlaceField(result['municipio'] ?? '');
    result['estado'] = _sanitizePlaceField(result['estado'] ?? '');
    result['codigoPostal'] = _sanitizeNumericField(
      result['codigoPostal'] ?? '',
      digits: 5,
    );
    result['seccionElectoral'] = _sanitizeNumericField(
      result['seccionElectoral'] ?? '',
      minDigits: 3,
      digits: 4,
    );
    result['seccion'] = result['seccionElectoral'] ?? '';
    result['fechaNacimiento'] = _sanitizeFechaField(
      result['fechaNacimiento'] ?? '',
    );
    result['vigencia'] = _sanitizeVigenciaField(result['vigencia'] ?? '');
    result['sexo'] = _sanitizeSexoField(result['sexo'] ?? '');
    result['curp'] = _sanitizeCurpField(result['curp'] ?? '');
    result['claveElectoral'] = _sanitizeClaveElectorField(
      result['claveElectoral'] ?? '',
    );
    result['claveElector'] = result['claveElectoral'] ?? '';

    return result;
  }

  String _sanitizeNameLikeField(String value) {
    var text = _stripDocumentFieldLabels(value);
    text = _cleanupNameValue(text);
    text = _stripForbiddenFieldTokens(
      text,
      const [
        'CURP',
        'CLAVE DE ELECTOR',
        'DOMICILIO',
        'DIRECCION',
        'SECCION',
        'VIGENCIA',
        'SEXO',
      ],
    );
    text = text.replaceAll(RegExp(r'[^A-ZÁÉÍÓÚÜÑ\s]', caseSensitive: false), ' ');
    text = _normalizeHumanText(text);
    if (!_looksLikeCleanName(text)) return '';
    return text;
  }

  String _sanitizePlaceField(String value) {
    var text = _stripDocumentFieldLabels(value);
    text = _normalizeHumanText(text);
    text = _stripForbiddenFieldTokens(
      text,
      const [
        'NOMBRE',
        'CURP',
        'CLAVE DE ELECTOR',
        'DOMICILIO',
        'DIRECCION',
        'SECCION',
        'VIGENCIA',
        'SEXO',
      ],
    );
    text = text.replaceAll(RegExp(r'[^A-ZÁÉÍÓÚÜÑ\s,\.]', caseSensitive: false), ' ');
    text = _normalizeHumanText(text);
    if (_containsAddressHints(text) || RegExp(r'\d').hasMatch(text)) return '';
    return text;
  }

  String _sanitizeAddressField(String value) {
    var text = _stripDocumentFieldLabels(value);
    text = _cleanupDireccionFinal(text);
    text = _stripForbiddenFieldTokens(
      text,
      const [
        'NOMBRE',
        'CURP',
        'CLAVE DE ELECTOR',
        'DOMICILIO',
        'DIRECCION',
        'SECCION',
        'VIGENCIA',
        'SEXO',
        'FECHA DE NACIMIENTO',
      ],
    );
    text = _dedupeRepeatedAddressPhrase(text);
    text = _normalizeHumanText(text);
    return text;
  }

  bool _looksLikeCleanName(String value) {
    final text = _normalizeHumanText(value);
    if (text.isEmpty) return false;
    if (_containsAddressHints(text)) return false;
    if (RegExp(r'\d').hasMatch(text)) return false;
    if (_containsForbiddenAddressContent(text)) return false;

    final words = text
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (words.isEmpty || words.length > 5) return false;
    if (words.any((word) => word.length < 2)) return false;
    return true;
  }

  bool _containsAddressHints(String value) {
    final normalized = _normalizeForCompare(value);
    return RegExp(
      r'\b(CALLE|CALZ|CALLEJON|AV|AVENIDA|ANDADOR|CDA|CERRADA|PRIV|PRIVADA|MZ|MANZANA|LT|LOTE|NUM|NO|N\.|#|CONJ|HAB|JARDIN|JARDINES)\b',
    ).hasMatch(normalized);
  }

  String _sanitizeNumericField(
    String value, {
    required int digits,
    int? minDigits,
  }) {
    final clean = _onlyDigits(_fixCommonNumericOcr(_normalizeText(value)));
    if (clean.isEmpty) return '';
    if (minDigits != null && clean.length < minDigits) return '';
    if (clean.length < digits) return clean;
    return clean.substring(0, digits);
  }

  String _sanitizeFechaField(String value) {
    final fixed = _fixFecha(
      _stripForbiddenFieldTokens(
        _stripDocumentFieldLabels(value),
        const ['FECHA DE NACIMIENTO', 'CURP', 'SECCION', 'VIGENCIA'],
      ),
    );
    return RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(fixed) ? fixed : '';
  }

  String _sanitizeVigenciaField(String value) {
    final fixed = _fixVigencia(
      _stripForbiddenFieldTokens(
        _stripDocumentFieldLabels(value),
        const ['VIGENCIA', 'SECCION', 'CURP', 'CLAVE DE ELECTOR'],
      ),
    );
    return RegExp(r'^\d{4}-\d{4}$').hasMatch(fixed) ? fixed : '';
  }

  String _sanitizeSexoField(String value) {
    final fixed = _fixSexo(
      _stripForbiddenFieldTokens(
        _stripDocumentFieldLabels(value),
        const ['SEXO', 'HOMBRE', 'MUJER'],
      ),
    );
    return (fixed == 'H' || fixed == 'M') ? fixed : '';
  }

  String _sanitizeCurpField(String value) {
    final fixed = _fixCurp(
      _stripForbiddenFieldTokens(
        _stripDocumentFieldLabels(value),
        const ['CURP', 'CLAVE DE ELECTOR', 'DOMICILIO', 'NOMBRE'],
      ),
    );
    return _curpExactRegex.hasMatch(fixed) ? fixed : '';
  }

  String _sanitizeClaveElectorField(String value) {
    final fixed = _fixClaveElector(
      _stripForbiddenFieldTokens(
        _stripDocumentFieldLabels(value),
        const ['CLAVE DE ELECTOR', 'CURP', 'DOMICILIO', 'NOMBRE'],
      ),
    );
    return _claveElectorExactRegex.hasMatch(fixed) ? fixed : '';
  }

  String _stripForbiddenFieldTokens(String value, List<String> tokens) {
    var text = _normalizeHumanText(value);
    for (final token in tokens) {
      final compact = _normalizeForCompare(token);
      text = text.replaceAll(
        RegExp(compact.replaceAll(' ', r'\s*'), caseSensitive: false),
        ' ',
      );
      text = text.replaceAll(
        RegExp(compact.replaceAll(' ', ''), caseSensitive: false),
        ' ',
      );
    }
    return _normalizeHumanText(text);
  }

  String _stripDocumentFieldLabels(String value) {
    var text = _normalizeHumanText(value);
    if (text.isEmpty) return '';

    final patterns = <RegExp>[
      RegExp(r'D[O0]M[I1L]C[I1L][I1L][O0QK]', caseSensitive: false),
      RegExp(r'D[O0]M[I1L][C0O][I1L][I1L][O0QK]', caseSensitive: false),
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

    return _normalizeHumanText(text);
  }

  Map<String, String> _mergeScanResults({
    required Map<String, String> primary,
    required Map<String, String> secondary,
  }) {
    final primaryValidation = OcrValidationService().validate(primary);
    final secondaryValidation = OcrValidationService().validate(secondary);

    const mergeKeys = [
      'claveElectoral',
      'sexo',
      'nombre',
      'apellidoPaterno',
      'apellidoMaterno',
      'direccion',
      'codigoPostal',
      'municipio',
      'estado',
      'vigencia',
      'seccionElectoral',
      'fechaNacimiento',
      'curp',
    ];

    final merged = Map<String, String>.from(primaryValidation.normalizedData);

    for (final key in mergeKeys) {
      final primaryScore = primaryValidation.confidence[key] ?? 0.0;
      final secondaryScore = secondaryValidation.confidence[key] ?? 0.0;
      final primaryValue = (primaryValidation.normalizedData[key] ?? '').trim();
      final secondaryValue =
          (secondaryValidation.normalizedData[key] ?? '').trim();

      if (secondaryValue.isEmpty) continue;

      final shouldUseSecondary =
          primaryValue.isEmpty ||
          secondaryScore > primaryScore + 0.15 ||
          (secondaryScore >= primaryScore &&
              secondaryValue.length > primaryValue.length);

      if (shouldUseSecondary) {
        merged[key] = secondaryValue;
      }
    }

    merged['claveElector'] = merged['claveElectoral'] ?? '';
    merged['seccion'] = merged['seccionElectoral'] ?? '';
    merged['rawText'] = _mergeTexts([
      primary['rawText'] ?? '',
      secondary['rawText'] ?? '',
    ]);

    final primaryMode = primary['processingMode'] ?? '';
    final secondaryMode = secondary['processingMode'] ?? '';
    merged['processingMode'] =
        primaryMode.contains('_cp') || secondaryMode.contains('_cp')
        ? 'hybrid_ocr_cp'
        : 'hybrid_ocr';

    return merged;
  }

  bool _shouldTrustModelResult(Map<String, String> modelResult) {
    final validation = OcrValidationService().validate(modelResult);
    final claveScore = validation.confidence['claveElectoral'] ?? 0.0;
    final curpScore = validation.confidence['curp'] ?? 0.0;
    final nombreScore = validation.confidence['nombre'] ?? 0.0;
    final apellidoScore = validation.confidence['apellidoPaterno'] ?? 0.0;
    final direccionScore = validation.confidence['direccion'] ?? 0.0;
    final sexoScore = validation.confidence['sexo'] ?? 0.0;
    final fechaScore = validation.confidence['fechaNacimiento'] ?? 0.0;
    final vigenciaScore = validation.confidence['vigencia'] ?? 0.0;
    final seccionScore = validation.confidence['seccionElectoral'] ?? 0.0;

    final strongIdentity = claveScore >= 0.76 || curpScore >= 0.76;
    final strongNames = nombreScore >= 0.64 && apellidoScore >= 0.62;
    final solidFormFields =
        direccionScore >= 0.28 &&
        sexoScore >= 0.62 &&
        fechaScore >= 0.62 &&
        vigenciaScore >= 0.60 &&
        seccionScore >= 0.58;

    return strongIdentity && strongNames && solidFormFields;
  }

  bool _isGoodEnoughModelResult(Map<String, String> modelResult) {
    final validation = OcrValidationService().validate(modelResult);
    final normalized = validation.normalizedData;

    final clave = (normalized['claveElectoral'] ?? '').trim();
    final curp = (normalized['curp'] ?? '').trim();
    final nombre = (normalized['nombre'] ?? '').trim();
    final apellidoPaterno = (normalized['apellidoPaterno'] ?? '').trim();
    final direccion = (normalized['direccion'] ?? '').trim();

    final identityPresent = clave.isNotEmpty || curp.isNotEmpty;
    final personPresent = nombre.isNotEmpty && apellidoPaterno.isNotEmpty;
    final addressPresent = direccion.isNotEmpty;

    return validation.globalConfidence >= 0.58 &&
        identityPresent &&
        personPresent &&
        addressPresent;
  }

  Future<Map<String, String>> _rescueDetectedFieldsIfNeeded({
    required Map<String, String> current,
    required String fullText,
    required Map<String, String> cropsByLabel,
    required Map<String, String> nameParts,
  }) async {
    final result = Map<String, String>.from(current);

    final currentValidation = OcrValidationService().validate(result);
    if (currentValidation.globalConfidence >= 0.68) {
      return result;
    }

    final claveValue = (result['claveElectoral'] ?? '').trim();
    if (!_claveElectorExactRegex.hasMatch(_fixClaveElector(claveValue))) {
      final extraClaveTexts = await _readStructuredFieldCandidates(
        cropsByLabel['clave_elector'],
      );
      final rescuedClave = _pickBestValue(
        sources: [...extraClaveTexts, fullText],
        extractor: (source) => _extractClaveElector(source, source),
        exactValidator: (value) =>
            _claveElectorExactRegex.hasMatch(_fixClaveElector(value)),
        fallbackValidator: (_) => false,
        normalizer: _fixClaveElector,
        acceptCandidate: _looksLikeStructuredClaveElectorCandidate,
      );
      if (_claveElectorExactRegex.hasMatch(_fixClaveElector(rescuedClave))) {
        result['claveElectoral'] = rescuedClave;
        result['claveElector'] = rescuedClave;
      }
    }

    final curpValue = (result['curp'] ?? '').trim();
    if (!_curpExactRegex.hasMatch(_fixCurp(curpValue))) {
      final extraCurpTexts = await _readStructuredFieldCandidates(
        cropsByLabel['curp'],
      );
      final rescuedCurp = _pickBestValue(
        sources: [...extraCurpTexts, fullText],
        extractor: (source) => _extractCurp(source, source),
        exactValidator: (value) => _curpExactRegex.hasMatch(_fixCurp(value)),
        fallbackValidator: (_) => false,
        normalizer: _fixCurp,
        acceptCandidate: _looksLikeStructuredCurpCandidate,
      );
      if (_curpExactRegex.hasMatch(_fixCurp(rescuedCurp))) {
        result['curp'] = rescuedCurp;
      }
    }

    final direccionValue = (result['direccion'] ?? '').trim();
    if (direccionValue.isEmpty || _addressLooksContaminated(direccionValue, nameParts)) {
      final extraDomicilioTexts = await _readStructuredFieldCandidates(
        cropsByLabel['domicilio'],
      );
      final extraDomicilioLines = await _readStructuredFieldLines(
        cropsByLabel['domicilio'],
      );
      final mergedDomicilioText = _mergeTexts(extraDomicilioTexts);
      final rescuedAddress = _extractAddressPartsFromStructuredZone(
        zoneLines: extraDomicilioLines,
        zoneText: mergedDomicilioText,
        fullText: fullText,
      );
      final rescuedDireccion = _sanitizeAddressWithName(
        (rescuedAddress['direccion'] ?? '').trim(),
        nameParts,
      );
      if (rescuedDireccion.isNotEmpty &&
          !_addressLooksContaminated(rescuedDireccion, nameParts)) {
        result['direccion'] = rescuedDireccion;
        result['codigoPostal'] =
            (rescuedAddress['codigoPostal'] ?? '').trim().isNotEmpty
            ? rescuedAddress['codigoPostal'] ?? ''
            : result['codigoPostal'] ?? '';
        result['municipio'] =
            (rescuedAddress['municipio'] ?? '').trim().isNotEmpty
            ? rescuedAddress['municipio'] ?? ''
            : result['municipio'] ?? '';
        result['estado'] =
            (rescuedAddress['estado'] ?? '').trim().isNotEmpty
            ? rescuedAddress['estado'] ?? ''
            : result['estado'] ?? '';
      }
    }

    return result;
  }

  bool _addressLooksContaminated(
    String direccion,
    Map<String, String> nameParts,
  ) {
    final normalizedAddress = _normalizeForCompare(direccion);
    if (normalizedAddress.isEmpty) return true;

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

    int matches = 0;
    for (final token in nameTokens) {
      if (normalizedAddress.contains(token)) {
        matches++;
      }
    }

    return matches >= 2;
  }

  Future<Map<String, String>> _scanUsingDetectedZones({
    required String imagePath,
    required Map<String, String> cropsByLabel,
  }) async {
    final fullText = await _readText(imagePath);

    final nombreText = await _readText(cropsByLabel['nombre']);
    final domicilioText = await _readText(cropsByLabel['domicilio']);
    final claveText = await _readText(cropsByLabel['clave_elector']);
    final curpText = await _readText(cropsByLabel['curp']);
    final fechaText = await _readText(cropsByLabel['fecha_nacimiento']);
    final seccionText = await _readText(cropsByLabel['seccion']);
    final sexoText = await _readText(cropsByLabel['sexo']);
    final vigenciaText = await _readText(cropsByLabel['vigencia']);
    final claveStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['clave_elector'],
    );
    final nombreStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['nombre'],
    );
    final nombreStructuredLines = await _readStructuredFieldLines(
      cropsByLabel['nombre'],
    );
    final domicilioStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['domicilio'],
    );
    final domicilioStructuredLines = await _readStructuredFieldLines(
      cropsByLabel['domicilio'],
    );
    final curpStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['curp'],
    );
    final fechaStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['fecha_nacimiento'],
    );
    final seccionStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['seccion'],
    );
    final vigenciaStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['vigencia'],
    );
    final sexoStructuredTexts = await _readStructuredFieldCandidatesFast(
      cropsByLabel['sexo'],
    );

    final mergedNombreText = _mergeTexts([
      ...nombreStructuredTexts,
      nombreText,
    ]);
    final mergedDomicilioText = _mergeTexts([
      ...domicilioStructuredTexts,
      domicilioText,
    ]);

    final nameParts = _extractNamePartsFromStructuredZone(
      zoneLines: nombreStructuredLines,
      zoneText: mergedNombreText,
      fullText: fullText,
    );
    final addressParts = _extractAddressPartsFromStructuredZone(
      zoneLines: domicilioStructuredLines,
      zoneText: mergedDomicilioText,
      fullText: fullText,
    );
    final sanitizedDireccion = _sanitizeAddressWithName(
      addressParts['direccion'] ?? '',
      nameParts,
    );

    final claveElectoral = _pickBestValue(
      sources: [...claveStructuredTexts, claveText, fullText],
      extractor: (source) => _extractClaveElector(source, source),
      exactValidator: (value) => _claveElectorExactRegex.hasMatch(
        _fixClaveElector(value),
      ),
      fallbackValidator: (value) => value.trim().length >= 14,
      normalizer: _fixClaveElector,
      acceptCandidate: _looksLikeStructuredClaveElectorCandidate,
    );

    final curp = _pickBestValue(
      sources: [...curpStructuredTexts, curpText, fullText],
      extractor: (source) => _extractCurp(source, source),
      exactValidator: (value) => _curpExactRegex.hasMatch(_fixCurp(value)),
      fallbackValidator: (value) => value.trim().length >= 14,
      normalizer: _fixCurp,
      acceptCandidate: _looksLikeStructuredCurpCandidate,
    );

    final fechaNacimiento = _pickBestValue(
      sources: [...fechaStructuredTexts, fechaText, fullText],
      extractor: (source) => _extractFechaNacimiento(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(_fixFecha(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixFecha,
      acceptCandidate: _looksLikeStructuredFechaCandidate,
    );

    final vigencia = _pickBestValue(
      sources: [...vigenciaStructuredTexts, vigenciaText, fullText],
      extractor: (source) => _extractVigencia(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{4}-\d{4}$').hasMatch(_fixVigencia(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixVigencia,
      acceptCandidate: _looksLikeStructuredVigenciaCandidate,
    );

    final seccionElectoral = _pickBestValue(
      sources: [...seccionStructuredTexts, seccionText, fullText],
      extractor: (source) => _extractSeccion(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{3,4}$').hasMatch(_fixSeccion(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixSeccion,
      acceptCandidate: _looksLikeStructuredSeccionCandidate,
    );

    final sexo = _pickBestValue(
      sources: [...sexoStructuredTexts, sexoText, fullText],
      extractor: (source) => _extractSexo(source, source),
      exactValidator: (value) {
        final fixed = _fixSexo(value);
        return fixed == 'H' || fixed == 'M';
      },
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixSexo,
    );

    final codigoPostal = _pickBestValue(
      sources: [...domicilioStructuredTexts, mergedDomicilioText, fullText],
      extractor: (source) => _extractCodigoPostal(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{5}$').hasMatch(_fixCodigoPostal(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixCodigoPostal,
      acceptCandidate: _looksLikeStructuredCodigoPostalCandidate,
    );

    final cpCatalogData = await _lookupCpData(codigoPostal);

    final estadoFinal = _preferCatalogValue(
      catalogValue: cpCatalogData?['estado'],
      ocrValue: addressParts['estado'] ?? '',
    );

    final municipioFinal = _preferCatalogValue(
      catalogValue: cpCatalogData?['municipio'],
      ocrValue: addressParts['municipio'] ?? '',
    );

    var result = {
      'processingMode': cpCatalogData != null ? 'model_ocr_cp' : 'model_ocr',
      'rawText': fullText,
      'claveElectoral': claveElectoral,
      'claveElector': claveElectoral,
      'sexo': sexo,
      'nombre': nameParts['nombre'] ?? '',
      'apellidoPaterno': nameParts['apellidoPaterno'] ?? '',
      'apellidoMaterno': nameParts['apellidoMaterno'] ?? '',
      'direccion': sanitizedDireccion,
      'codigoPostal': codigoPostal,
      'municipio': municipioFinal,
      'estado': estadoFinal,
      'vigencia': vigencia,
      'seccionElectoral': seccionElectoral,
      'seccion': seccionElectoral,
      'fechaNacimiento': fechaNacimiento,
      'curp': curp,
    };

    result = await _rescueDetectedFieldsIfNeeded(
      current: result,
      fullText: fullText,
      cropsByLabel: cropsByLabel,
      nameParts: nameParts,
    );

    return result;
  }

  Future<Map<String, String>> _scanUsingFixedZones(String imagePath) async {
    final prepared = await _prepareImageVariants(imagePath);

    final fullTexts = await _readTextCandidates(prepared.fullPaths);
    final nameTexts = await _readTextCandidates(prepared.nameZonePaths);
    final addressTexts = await _readTextCandidates(prepared.addressZonePaths);
    final dataTexts = await _readTextCandidates(prepared.dataZonePaths);

    final fullText = _mergeTexts(fullTexts);
    final nameText = _mergeTexts(nameTexts);
    final addressText = _mergeTexts(addressTexts);
    final dataText = _mergeTexts(dataTexts);

    final nameParts = _extractNameParts(nameText, fullText);
    final addressParts = _extractAddressParts(addressText, fullText);
    final sanitizedDireccion = _sanitizeAddressWithName(
      addressParts['direccion'] ?? '',
      nameParts,
    );

    final claveElectoral = _pickBestValue(
      sources: [...dataTexts, dataText, ...fullTexts, fullText],
      extractor: (source) => _extractClaveElector(source, source),
      exactValidator: (value) => _claveElectorExactRegex.hasMatch(
        _fixClaveElector(value),
      ),
      fallbackValidator: (value) => value.trim().length >= 14,
      normalizer: _fixClaveElector,
      acceptCandidate: _looksLikeStructuredClaveElectorCandidate,
    );

    final curp = _pickBestValue(
      sources: [...dataTexts, dataText, ...fullTexts, fullText],
      extractor: (source) => _extractCurp(source, source),
      exactValidator: (value) => _curpExactRegex.hasMatch(_fixCurp(value)),
      fallbackValidator: (value) => value.trim().length >= 14,
      normalizer: _fixCurp,
      acceptCandidate: _looksLikeStructuredCurpCandidate,
    );

    final fechaNacimiento = _pickBestValue(
      sources: [...dataTexts, dataText, ...fullTexts, fullText],
      extractor: (source) => _extractFechaNacimiento(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(_fixFecha(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixFecha,
      acceptCandidate: _looksLikeStructuredFechaCandidate,
    );

    final vigencia = _pickBestValue(
      sources: [...dataTexts, dataText, ...fullTexts, fullText],
      extractor: (source) => _extractVigencia(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{4}-\d{4}$').hasMatch(_fixVigencia(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixVigencia,
      acceptCandidate: _looksLikeStructuredVigenciaCandidate,
    );

    final seccionElectoral = _pickBestValue(
      sources: [...dataTexts, dataText, ...fullTexts, fullText],
      extractor: (source) => _extractSeccion(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{3,4}$').hasMatch(_fixSeccion(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixSeccion,
      acceptCandidate: _looksLikeStructuredSeccionCandidate,
    );

    final sexo = _pickBestValue(
      sources: [...dataTexts, dataText, ...fullTexts, fullText],
      extractor: (source) => _extractSexo(source, source),
      exactValidator: (value) {
        final fixed = _fixSexo(value);
        return fixed == 'H' || fixed == 'M';
      },
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixSexo,
    );

    final codigoPostal = _pickBestValue(
      sources: [addressText, ...addressTexts, fullText, ...fullTexts],
      extractor: (source) => _extractCodigoPostal(source, source),
      exactValidator: (value) =>
          RegExp(r'^\d{5}$').hasMatch(_fixCodigoPostal(value)),
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _fixCodigoPostal,
      acceptCandidate: _looksLikeStructuredCodigoPostalCandidate,
    );

    final estadoOcr = _pickBestValue(
      sources: [addressText, ...addressTexts, fullText, ...fullTexts],
      extractor: (source) {
        final parts = _extractAddressParts(source, fullText);
        return parts['estado'] ?? '';
      },
      exactValidator: (value) => value.trim().isNotEmpty,
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _normalizeHumanText,
    );

    final municipioOcr = _pickBestValue(
      sources: [addressText, ...addressTexts, fullText, ...fullTexts],
      extractor: (source) {
        final parts = _extractAddressParts(source, fullText);
        return parts['municipio'] ?? '';
      },
      exactValidator: (value) => value.trim().isNotEmpty,
      fallbackValidator: (value) => value.trim().isNotEmpty,
      normalizer: _normalizeHumanText,
    );

    final cpCatalogData = await _lookupCpData(codigoPostal);

    final estadoFinal = _preferCatalogValue(
      catalogValue: cpCatalogData?['estado'],
      ocrValue: estadoOcr.isNotEmpty ? estadoOcr : (addressParts['estado'] ?? ''),
    );

    final municipioFinal = _preferCatalogValue(
      catalogValue: cpCatalogData?['municipio'],
      ocrValue: municipioOcr.isNotEmpty
          ? municipioOcr
          : (addressParts['municipio'] ?? ''),
    );

    final direccion = sanitizedDireccion;

    return {
      'processingMode': cpCatalogData != null ? 'ocr_cp' : 'ocr_only',
      'rawText': fullText,
      'claveElectoral': claveElectoral,
      'claveElector': claveElectoral,
      'sexo': sexo,
      'nombre': nameParts['nombre'] ?? '',
      'apellidoPaterno': nameParts['apellidoPaterno'] ?? '',
      'apellidoMaterno': nameParts['apellidoMaterno'] ?? '',
      'direccion': direccion,
      'codigoPostal': codigoPostal,
      'municipio': municipioFinal,
      'estado': estadoFinal,
      'vigencia': vigencia,
      'seccionElectoral': seccionElectoral,
      'seccion': seccionElectoral,
      'fechaNacimiento': fechaNacimiento,
      'curp': curp,
    };
  }

  Future<_PreparedOcrImage> _prepareImageVariants(String path) async {
    final bytes = await File(path).readAsBytes();
    final decoded = img.decodeImage(bytes);

    if (decoded == null) {
      return _PreparedOcrImage(
        fullPaths: [path],
        nameZonePaths: [path],
        addressZonePaths: [path],
        dataZonePaths: [path],
      );
    }

    final resized = decoded.width > _maxOcrWidth
        ? img.copyResize(
            decoded,
            width: _maxOcrWidth,
          )
        : decoded;
    final variants = _buildVariants(resized);

    final base =
        '${Directory.systemTemp.path}/guardianes4t_${DateTime.now().microsecondsSinceEpoch}';

    final fullPaths = <String>[];
    final namePaths = <String>[];
    final addressPaths = <String>[];
    final dataPaths = <String>[];

    for (int i = 0; i < variants.length; i++) {
      final current = variants[i];
      final width = current.width;
      final height = current.height;

      final nameZone = img.copyCrop(
        current,
        x: (width * 0.08).round(),
        y: (height * 0.16).round(),
        width: (width * 0.56).round(),
        height: (height * 0.20).round(),
      );

      final addressZone = img.copyCrop(
        current,
        x: (width * 0.08).round(),
        y: (height * 0.34).round(),
        width: (width * 0.60).round(),
        height: (height * 0.26).round(),
      );

      final dataZone = img.copyCrop(
        current,
        x: (width * 0.54).round(),
        y: (height * 0.14).round(),
        width: (width * 0.38).round(),
        height: (height * 0.58).round(),
      );

      final fullPath = '${base}_full_$i.jpg';
      final namePath = '${base}_name_$i.jpg';
      final addressPath = '${base}_address_$i.jpg';
      final dataPath = '${base}_data_$i.jpg';

      await File(fullPath).writeAsBytes(img.encodeJpg(current, quality: 82));
      await File(namePath).writeAsBytes(img.encodeJpg(nameZone, quality: 84));
      await File(addressPath)
          .writeAsBytes(img.encodeJpg(addressZone, quality: 84));
      await File(dataPath).writeAsBytes(img.encodeJpg(dataZone, quality: 84));

      fullPaths.add(fullPath);
      namePaths.add(namePath);
      addressPaths.add(addressPath);
      dataPaths.add(dataPath);
    }

    return _PreparedOcrImage(
      fullPaths: fullPaths,
      nameZonePaths: namePaths,
      addressZonePaths: addressPaths,
      dataZonePaths: dataPaths,
    );
  }

  Future<List<String>> _prepareRescueImageVariants(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return const [];

      final resized = decoded.width > _maxOcrWidth
          ? img.copyResize(
              decoded,
              width: _maxOcrWidth,
            )
          : decoded;
      final gray = img.grayscale(img.Image.from(resized));
      final contrast = img.adjustColor(
        img.Image.from(gray),
        contrast: 1.24,
        brightness: 1.03,
      );
      final base =
          '${Directory.systemTemp.path}/guardianes4t_rescue_${DateTime.now().microsecondsSinceEpoch}';
      final output = <String>[];
      final images = [contrast];

      for (int i = 0; i < images.length; i++) {
        final currentPath = '${base}_$i.jpg';
        await File(currentPath).writeAsBytes(
          img.encodeJpg(images[i], quality: 84),
        );
        output.add(currentPath);
      }

      return output;
    } catch (_) {
      return const [];
    }
  }

  List<img.Image> _buildVariants(img.Image source) {
    final base = source;
    return [base];
  }

  Future<List<String>> _readTextCandidates(List<String> paths) async {
    final results = <String>[];

    for (final path in paths) {
      final texts = await _readTextVariants(path);
      for (final text in texts) {
        if (text.trim().isNotEmpty) {
          results.add(text);
        }
      }
    }

    return results.toSet().toList();
  }

  Future<List<String>> _readStructuredFieldCandidates(String? path) async {
    if (path == null || path.isEmpty) return const [];

    final baseTexts = await _readTextVariants(path);
    final variants = await _prepareStructuredFieldVariants(path);
    final variantTexts = await _readTextCandidates(variants);

    return {
      ...baseTexts,
      ...variantTexts,
    }.toList();
  }

  Future<List<String>> _readStructuredFieldCandidatesFast(String? path) async {
    if (path == null || path.isEmpty) return const [];
    return _readTextVariants(path);
  }

  Future<List<String>> _readStructuredFieldLines(String? path) async {
    if (path == null || path.isEmpty) return const [];

    final baseRecognized = await _readRecognizedText(path);
    final lines = <String>[];

    void collectLines(RecognizedText recognized) {
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final text = line.text.replaceAll('\r', '').trim();
          if (text.isNotEmpty) {
            lines.add(text);
          }

          final elements = line.elements
              .map((e) => e.text.replaceAll('\r', '').trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (elements.isNotEmpty) {
            lines.add(elements.join(' '));
          }
        }
      }
    }

    if (baseRecognized != null) {
      collectLines(baseRecognized);
    }

    if (lines.length >= 2) {
      return lines.toSet().toList();
    }

    final variants = await _prepareStructuredFieldVariants(path);

    for (final variantPath in variants) {
      final recognized = await _readRecognizedText(variantPath);
      if (recognized == null) continue;

      collectLines(recognized);
    }

    return lines.toSet().toList();
  }

  Future<List<String>> _readTextVariants(String? path) async {
    if (path == null || path.isEmpty) return const [];

    try {
      final recognized = await _readRecognizedText(path);
      if (recognized == null) return const [];

      final rawText = recognized.text.replaceAll('\r', '').trim();
      final lineTexts = <String>[];
      final elementLineTexts = <String>[];
      final allElements = <String>[];

      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final lineText = line.text.replaceAll('\r', '').trim();
          if (lineText.isNotEmpty) {
            lineTexts.add(lineText);
          }

          final elements = line.elements
              .map((e) => e.text.replaceAll('\r', '').trim())
              .where((e) => e.isNotEmpty)
              .toList();

          if (elements.isNotEmpty) {
            elementLineTexts.add(elements.join(' '));
            allElements.addAll(elements);
          }
        }
      }

      return {
        if (rawText.isNotEmpty) rawText,
        if (lineTexts.isNotEmpty) lineTexts.join('\n'),
        if (elementLineTexts.isNotEmpty) elementLineTexts.join('\n'),
        if (allElements.isNotEmpty) allElements.join(' '),
      }.toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _prepareStructuredFieldVariants(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return const [];

      final enlarged = decoded.width > 720
          ? img.copyResize(
              decoded,
              width: 720,
            )
          : decoded;
      final gray = img.grayscale(img.Image.from(enlarged));
      final contrast = img.adjustColor(
        img.Image.from(gray),
        contrast: 1.35,
        brightness: 1.04,
      );

      final base =
          '${Directory.systemTemp.path}/guardianes4t_field_${DateTime.now().microsecondsSinceEpoch}';

      final paths = <String>[];
      final images = [contrast];

      for (int i = 0; i < images.length; i++) {
        final variantPath = '${base}_$i.jpg';
        await File(variantPath).writeAsBytes(
          img.encodeJpg(images[i], quality: 84),
        );
        paths.add(variantPath);
      }

      return paths;
    } catch (_) {
      return const [];
    }
  }

  Future<String> _readText(String? path) async {
    if (path == null || path.isEmpty) return '';

    try {
      final result = await _readRecognizedText(path);
      return result?.text.replaceAll('\r', '') ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<RecognizedText?> _readRecognizedText(String path) async {
    return _recognizedTextCache.putIfAbsent(path, () async {
      try {
        final image = InputImage.fromFilePath(path);
        return await _recognizer.processImage(image);
      } catch (_) {
        return null;
      }
    });
  }

  String _mergeTexts(List<String> texts) {
    final clean = texts
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();

    return clean.join('\n');
  }

  String _pickBestValue({
    required List<String> sources,
    required String Function(String source) extractor,
    required bool Function(String value) exactValidator,
    required bool Function(String value) fallbackValidator,
    required String Function(String value) normalizer,
    bool Function(String value)? acceptCandidate,
  }) {
    String bestValue = '';
    double bestScore = -1;

    double computeScore(String value) {
      if (exactValidator(value)) return 1000 + value.length.toDouble();
      if (fallbackValidator(value)) return 100 + value.length.toDouble();
      return value.length.toDouble();
    }

    for (final source in sources) {
      final raw = extractor(source).trim();
      if (raw.isEmpty) continue;

      final value = normalizer(raw);
      if (value.isEmpty) continue;
      if (acceptCandidate != null && !acceptCandidate(value)) continue;

      final score = computeScore(value);

      if (score > bestScore) {
        bestScore = score;
        bestValue = value;
      }
    }

    return bestValue;
  }

  bool _looksLikeStructuredClaveElectorCandidate(String value) {
    final normalized = _normalizeText(value).replaceAll(' ', '');
    if (normalized.isEmpty || normalized.length < 17 || normalized.length > 19) {
      return false;
    }
    return RegExp(r'^[A-Z0-9]+$').hasMatch(normalized);
  }

  bool _looksLikeStructuredCurpCandidate(String value) {
    final normalized = _normalizeText(value).replaceAll(' ', '');
    if (normalized.isEmpty || normalized.length > 20) return false;
    return RegExp(r'^[A-Z0-9]+$').hasMatch(normalized);
  }

  bool _looksLikeStructuredFechaCandidate(String value) {
    final normalized = _normalizeHumanText(value);
    return normalized.isNotEmpty && normalized.length <= 12;
  }

  bool _looksLikeStructuredVigenciaCandidate(String value) {
    final normalized = _normalizeHumanText(value);
    return normalized.isNotEmpty && normalized.length <= 12;
  }

  bool _looksLikeStructuredSeccionCandidate(String value) {
    final normalized = _onlyDigits(_normalizeHumanText(value));
    return normalized.isNotEmpty && normalized.length <= 4;
  }

  bool _looksLikeStructuredCodigoPostalCandidate(String value) {
    final normalized = _onlyDigits(_normalizeHumanText(value));
    return normalized.isNotEmpty && normalized.length <= 5;
  }

  String _normalizeText(String text) {
    return text
        .replaceAll('\r', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .toUpperCase();
  }

  String _normalizeForCompare(String text) {
    return _normalizeText(text)
        .replaceAll('Á', 'A')
        .replaceAll('É', 'E')
        .replaceAll('Í', 'I')
        .replaceAll('Ó', 'O')
        .replaceAll('Ú', 'U')
        .replaceAll('Ü', 'U')
        .replaceAll('Ñ', 'N');
  }

  String _normalizeHumanText(String text) {
    return text
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _onlyDigits(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }

  String _fixCommonNumericOcr(String value) {
    return value
        .replaceAll('O', '0')
        .replaceAll('Q', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1')
        .replaceAll('Z', '2')
        .replaceAll('S', '5')
        .replaceAll('B', '8');
  }

  String _fixCommonAlphaOcr(String value) {
    return value
        .replaceAll('0', 'O')
        .replaceAll('1', 'I')
        .replaceAll('2', 'Z')
        .replaceAll('5', 'S')
        .replaceAll('8', 'B');
  }

  String _fixClaveElector(String value) {
    final raw = _normalizeText(value).replaceAll(' ', '');
    if (raw.isEmpty) return raw;

    final chars = raw.split('');
    for (int i = 0; i < chars.length; i++) {
      if (i >= 0 && i <= 5) {
        chars[i] = _fixCommonAlphaOcr(chars[i]);
      }
      if (i >= 6 && i <= 13) {
        chars[i] = _fixCommonNumericOcr(chars[i]);
      }
      if (i == 14) {
        chars[i] = _fixClaveSexoMarker(chars[i]);
      }
      if (i >= 15 && i <= 17) {
        chars[i] = _fixCommonNumericOcr(chars[i]);
      }
    }

    final fixed = chars.join();
    final compactMatches = _extractCompactRegexMatches(fixed, _claveElectorLooseRegex);
    if (compactMatches.isNotEmpty) {
      final best = compactMatches.first;
      if (best.length == 18) return best;
    }

    return fixed;
  }

  String _fixClaveSexoMarker(String value) {
    final raw = _normalizeText(value);
    if (raw.isEmpty) return raw;
    if (raw == 'H' || raw == 'M') return raw;
    if (raw == 'N') return 'H';
    if (raw == '0' || raw == 'O') return 'H';
    if (raw == '1' || raw == 'I' || raw == 'L') return 'H';
    if (raw.contains('M')) return 'M';
    if (raw.contains('H')) return 'H';
    return raw;
  }

  String _fixCurp(String value) {
    final raw = _normalizeText(value).replaceAll(' ', '');
    if (raw.isEmpty) return raw;

    final chars = raw.split('');
    for (int i = 0; i < chars.length; i++) {
      if (i <= 3 || (i >= 11 && i <= 15)) {
        chars[i] = _fixCommonAlphaOcr(chars[i]);
      }
      if (i >= 4 && i <= 9) {
        chars[i] = _fixCommonNumericOcr(chars[i]);
      }
      if (i == 10) {
        chars[i] = _fixCurpSexoMarker(chars[i]);
      }
    }

    final fixed = chars.join();
    final compactMatches = _extractCompactRegexMatches(fixed, _curpLooseRegex);
    if (compactMatches.isNotEmpty) {
      return compactMatches.first;
    }

    return fixed;
  }

  String _fixCurpSexoMarker(String value) {
    final raw = _normalizeText(value);
    if (raw.isEmpty) return raw;
    if (raw == 'H' || raw == 'M') return raw;
    if (raw == 'N') return 'H';
    if (raw == '0' || raw == 'O') return 'H';
    if (raw == '1' || raw == 'I' || raw == 'L') return 'H';
    if (raw.contains('M')) return 'M';
    if (raw.contains('H')) return 'H';
    return raw;
  }

  String _fixFecha(String value) {
    final raw = _fixCommonNumericOcr(_normalizeHumanText(value).toUpperCase())
        .replaceAll('-', '/')
        .replaceAll('.', '/')
        .replaceAll(RegExp(r'[^0-9/]'), '');

    final direct = RegExp(r'(\d{2})/(\d{2})/(\d{4})').firstMatch(raw);
    if (direct != null) {
      final day = direct.group(1) ?? '';
      final month = direct.group(2) ?? '';
      final year = direct.group(3) ?? '';
      if (_looksValidDateParts(day, month, year)) {
        return '$day/$month/$year';
      }
    }

    final digits = _onlyDigits(raw);
    if (digits.length >= 8) {
      final day = digits.substring(0, 2);
      final month = digits.substring(2, 4);
      final year = digits.substring(4, 8);
      if (_looksValidDateParts(day, month, year)) {
        return '$day/$month/$year';
      }
    }

    return raw;
  }

  String _fixVigencia(String value) {
    final raw = _fixCommonNumericOcr(_normalizeText(value))
        .replaceAll(' ', '')
        .replaceAll('/', '-')
        .replaceAll('_', '-')
        .replaceAll('.', '-');

    final direct = RegExp(r'(\d{4})-(\d{4})').firstMatch(raw);
    if (direct != null) {
      final first = direct.group(1) ?? '';
      final second = direct.group(2) ?? '';
      if (_looksValidVigenciaParts(first, second)) {
        return '$first-$second';
      }
    }

    final digits = _onlyDigits(_fixCommonNumericOcr(raw));
    if (digits.length >= 8) {
      final first = digits.substring(0, 4);
      final second = digits.substring(4, 8);
      if (_looksValidVigenciaParts(first, second)) {
        return '$first-$second';
      }
    }

    return raw;
  }

  String _fixSeccion(String value) {
    final digits = _onlyDigits(_fixCommonNumericOcr(_normalizeText(value)));
    final directMatch = RegExp(r'\d{3,4}').firstMatch(digits);
    if (directMatch != null) {
      return directMatch.group(0) ?? '';
    }
    if (digits.length >= 4) return digits.substring(0, 4);
    return digits;
  }

  bool _looksValidDateParts(String day, String month, String year) {
    final d = int.tryParse(day);
    final m = int.tryParse(month);
    final y = int.tryParse(year);
    if (d == null || m == null || y == null) return false;
    if (d < 1 || d > 31) return false;
    if (m < 1 || m > 12) return false;
    if (y < 1900 || y > 2099) return false;
    return true;
  }

  bool _looksValidVigenciaParts(String first, String second) {
    final from = int.tryParse(first);
    final to = int.tryParse(second);
    if (from == null || to == null) return false;
    if (from < 1990 || from > 2099) return false;
    if (to < from || to > from + 20) return false;
    return true;
  }

  String _fixCodigoPostal(String value) {
    final digits = _onlyDigits(_fixCommonNumericOcr(_normalizeText(value)));
    if (digits.length >= 5) return digits.substring(0, 5);
    return digits;
  }

  String _fixSexo(String value) {
    final raw = _normalizeText(value);
    if (raw == 'HOMBRE') return 'H';
    if (raw == 'MUJER') return 'M';
    if (raw == 'N') return 'H';
    if (raw == 'M') return 'M';
    if (raw.contains('H')) return 'H';
    if (raw.contains('M')) return 'M';
    return raw;
  }

  List<String> _cleanLines(String text) {
    return text
        .replaceAll('\r', '')
        .split('\n')
        .map((e) => _normalizeHumanText(e))
        .where((e) => e.isNotEmpty)
        .toList();
  }

  bool _looksLikeLabel(String line) {
    final normalized = _normalizeForCompare(line);

    const labels = [
      'NOMBRE',
      'DOMICILIO',
      'CLAVE DE ELECTOR',
      'CURP',
      'FECHA DE NACIMIENTO',
      'SECCION',
      'SECCIÓN',
      'VIGENCIA',
      'SEXO',
      'ESTADO',
      'MUNICIPIO',
      'LOCALIDAD',
      'EMISION',
      'EMISIÓN',
      'AÑO DE REGISTRO',
      'ANO DE REGISTRO',
    ];

    return labels.contains(normalized);
  }

  bool _looksLikeHeaderNoise(String line) {
    final normalized = _normalizeForCompare(line);

    const badPhrases = [
      'CREDENCIAL',
      'PARA',
      'VOTAR',
      'INSTITUTO',
      'NACIONAL',
      'ELECTORAL',
      'IDENTIDAD',
      'MEXICO',
    ];

    for (final phrase in badPhrases) {
      if (normalized.contains(phrase)) return true;
    }

    return false;
  }

  bool _looksLikeForeignDataLine(String line) {
    final normalized = _normalizeForCompare(line);

    final patterns = <RegExp>[
      RegExp(r'CLAVE\s+DE\s+ELECTOR'),
      RegExp(r'\bCURP\b'),
      RegExp(r'FECHA\s+DE\s+NACIMIENTO'),
      RegExp(r'\bSECCI?ON\b'),
      RegExp(r'\bVIGENCIA\b'),
      RegExp(r'\bSEXO\b'),
      RegExp(r'\bHOMBRE\b'),
      RegExp(r'\bMUJER\b'),
      RegExp(r'^[A-Z]{6}[0-9OILSZBQ]{6}[A-Z][0-9OILSZBQ]{3}$'),
      RegExp(r'^[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}$'),
      RegExp(r'\b\d{2}[\/\.-]\d{2}[\/\.-]\d{4}\b'),
      RegExp(r'\b\d{4}\s*[-\/]\s*\d{4}\b'),
      RegExp(r'^\d{3,4}$'),
      RegExp(r'\b[HMN]\b'),
    ];

    for (final pattern in patterns) {
      if (pattern.hasMatch(normalized)) return true;
    }

    return false;
  }

  bool _containsForbiddenAddressContent(String value) {
    final normalized = _normalizeForCompare(value);

    final forbiddenPatterns = <RegExp>[
      RegExp(r'CLAVE\s+DE\s+ELECTOR'),
      RegExp(r'\bCURP\b'),
      RegExp(r'FECHA\s+DE\s+NACIMIENTO'),
      RegExp(r'\bSECCI?ON\b'),
      RegExp(r'\bVIGENCIA\b'),
      RegExp(r'\bSEXO\b'),
      RegExp(r'\bHOMBRE\b'),
      RegExp(r'\bMUJER\b'),
      RegExp(r'\bEMISION\b'),
      RegExp(r'\bANO\s+DE\s+REGISTRO\b'),
      RegExp(r'\bAÑO\s+DE\s+REGISTRO\b'),
      RegExp(r'\b[A-Z]{6}[0-9OILSZBQ]{6}[A-Z][0-9OILSZBQ]{3}\b'),
      RegExp(r'\b[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}\b'),
      RegExp(r'\b\d{2}[\/\.-]\d{2}[\/\.-]\d{4}\b'),
      RegExp(r'\b\d{4}\s*[-\/]\s*\d{4}\b'),
    ];

    for (final pattern in forbiddenPatterns) {
      if (pattern.hasMatch(normalized)) return true;
    }

    return false;
  }

  Map<String, String> _extractNameParts(String nameText, String fullText) {
    final labeledFull = _extractLinesAfterLabel(
      fullText,
      'NOMBRE',
      stopLabels: const ['DOMICILIO', 'SEXO', 'CLAVE DE ELECTOR'],
      maxLines: 4,
    );

    final labeledZone = _extractNameLines(nameText);
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
      return {
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

  Map<String, String> _extractNamePartsFromStructuredZone({
    required List<String> zoneLines,
    required String zoneText,
    required String fullText,
  }) {
    final filteredLines = zoneLines.where((line) {
      if (_normalizeForCompare(line) == 'NOMBRE') return false;
      if (_looksLikeLabel(line)) return false;
      if (_looksLikeHeaderNoise(line)) return false;
      if (_looksLikeForeignDataLine(line)) return false;
      if (RegExp(r'^\d+$').hasMatch(_normalizeForCompare(line))) return false;
      if (RegExp(r'^\d{5}$').hasMatch(_normalizeForCompare(line))) return false;
      return true;
    }).toList();

    if (filteredLines.isNotEmpty) {
      if (filteredLines.length >= 3) {
        return {
          'apellidoPaterno': _cleanupNameValue(filteredLines[0]),
          'apellidoMaterno': _cleanupNameValue(filteredLines[1]),
          'nombre': _cleanupNameValue(filteredLines.sublist(2).join(' ')),
        };
      }

      if (filteredLines.length == 2) {
        return {
          'apellidoPaterno': _cleanupNameValue(filteredLines[0]),
          'apellidoMaterno': '',
          'nombre': _cleanupNameValue(filteredLines[1]),
        };
      }
    }

    return _extractNameParts(zoneText, fullText);
  }

  List<String> _extractNameLines(String text) {
    final lines = _cleanLines(text);

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

  Map<String, String> _extractAddressParts(String addressText, String fullText) {
    final addressLines = _extractAddressLines(addressText, fullText);

    String direccion = '';
    String municipio = '';
    String estado = '';

    if (addressLines.isNotEmpty) {
      final candidateLines = [...addressLines];
      final municipioEstado = _extractMunicipioEstadoFromLines(candidateLines);
      municipio = municipioEstado['municipio'] ?? '';
      estado = municipioEstado['estado'] ?? '';

      final addressCandidates = candidateLines.where((line) {
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

    final cpFromAddress = _fixCodigoPostal(
      _extractCodigoPostal(addressText, fullText),
    );

    direccion = _cleanupDireccionFinal(direccion);

    if (municipio.isNotEmpty &&
        _normalizeForCompare(direccion) == _normalizeForCompare(municipio)) {
      direccion = '';
    }

    if (estado.isNotEmpty &&
        _normalizeForCompare(direccion) == _normalizeForCompare(estado)) {
      direccion = '';
    }

    if (!_looksUsefulAddress(direccion)) {
      direccion = '';
    }

    return {
      'direccion': direccion,
      'codigoPostal': cpFromAddress,
      'municipio': municipio,
      'estado': estado,
    };
  }

  Map<String, String> _extractAddressPartsFromStructuredZone({
    required List<String> zoneLines,
    required String zoneText,
    required String fullText,
  }) {
    final filteredLines = zoneLines.where((line) {
      if (_looksLikeLabel(line)) return false;
      if (_looksLikeHeaderNoise(line)) return false;
      if (_looksLikeForeignDataLine(line)) return false;
      if (_containsForbiddenAddressContent(line)) return false;
      return true;
    }).toList();

    if (filteredLines.isEmpty) {
      return _extractAddressParts(zoneText, fullText);
    }

    String direccion = '';
    String municipio = '';
    String estado = '';

    final firstUseful = filteredLines.firstWhere(
      (line) => _looksUsefulAddress(line),
      orElse: () => '',
    );

    final municipioEstado = _extractMunicipioEstadoFromLines(filteredLines);
    municipio = municipioEstado['municipio'] ?? '';
    estado = municipioEstado['estado'] ?? '';

    final addressCandidates = filteredLines.where((line) {
      final clean = _cleanupDireccionFinal(line);
      if (clean.isEmpty) return false;
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
      direccion = _cleanupDireccionFinal(
        _buildDireccionFromLines(
          addressCandidates,
          municipio: municipio,
          estado: estado,
        ),
      );
    } else if (firstUseful.isNotEmpty) {
      direccion = _cleanupDireccionFinal(firstUseful);
    }

    final cpFromAddress = _fixCodigoPostal(_extractCodigoPostal(zoneText, fullText));

    if (municipio.isNotEmpty &&
        _normalizeForCompare(direccion) == _normalizeForCompare(municipio)) {
      direccion = '';
    }

    if (estado.isNotEmpty &&
        _normalizeForCompare(direccion) == _normalizeForCompare(estado)) {
      direccion = '';
    }

    if (!_looksUsefulAddress(direccion)) {
      direccion = '';
    }

    return {
      'direccion': direccion,
      'codigoPostal': cpFromAddress,
      'municipio': municipio,
      'estado': estado,
    };
  }

  List<String> _extractAddressLines(String addressText, String fullText) {
    final zoneLines = _cleanLines(addressText).where((line) {
      if (_looksLikeLabel(line)) return false;
      if (_looksLikeHeaderNoise(line)) return false;
      if (_looksLikeForeignDataLine(line)) return false;
      if (_containsForbiddenAddressContent(line)) return false;
      return true;
    }).toList();

    final labeledFull = _extractLinesAfterLabel(
      fullText,
      'DOMICILIO',
      stopLabels: const [
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'SECCIÓN',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
        'NOMBRE',
      ],
      maxLines: 4,
    );

    final filteredLabeledFull = labeledFull.where((line) {
      if (_looksLikeForeignDataLine(line)) return false;
      if (_containsForbiddenAddressContent(line)) return false;
      return true;
    }).toList();

    final merged = <String>[];
    final seen = <String>{};

    for (final line in [...zoneLines, ...filteredLabeledFull]) {
      final clean = _cleanupDireccionFinal(line);
      final normalized = _normalizeForCompare(clean);
      if (clean.isEmpty || normalized.isEmpty || seen.contains(normalized)) {
        continue;
      }
      seen.add(normalized);
      merged.add(clean);
    }

    return merged;
  }

  Map<String, String> _extractMunicipioEstadoFromLines(List<String> lines) {
    if (lines.isEmpty) {
      return {
        'municipio': '',
        'estado': '',
      };
    }

    for (int i = lines.length - 1; i >= 0; i--) {
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

    return {
      'municipio': '',
      'estado': '',
    };
  }

  Map<String, String> _parseMunicipioEstado(String line) {
    final clean = _normalizeHumanText(line);
    if (clean.isEmpty) {
      return {
        'municipio': '',
        'estado': '',
      };
    }

    if (_looksLikeForeignDataLine(clean) ||
        _containsForbiddenAddressContent(clean)) {
      return {
        'municipio': '',
        'estado': '',
      };
    }

    final upper = _normalizeForCompare(clean);

    for (final state in _mexicanStates) {
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
        'estado': 'MÉXICO',
      };
    }

    return {
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
      r'\b(CALLE|CALZ|CALLEJON|AV|AVENIDA|ANDADOR|CDA|CERRADA|PRIV|PRIVADA|MZ|MANZANA|LT|LOTE|NUM|NO|N\\.|#)\b',
    ).hasMatch(normalized);
    final hasDigits = RegExp(r'\d').hasMatch(normalized);

    if (!hasStreetHint && !hasDigits && text.length < 8) {
      return false;
    }

    // Avoid accepting full-name lines inside the domicilio block.
    if (!hasStreetHint &&
        !hasDigits &&
        RegExp(r'^[A-Z\s]+$').hasMatch(normalized) &&
        words.length >= 2 &&
        words.length <= 5) {
      return false;
    }

    if (RegExp(r'^[A-Z\s]+$').hasMatch(normalized) &&
        words.length <= 2) {
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

    text = _stripForbiddenFieldTokens(
      text,
      const [
        'DOMICILIO',
        'DIRECCION',
        'CURP',
        'CLAVE DE ELECTOR',
        'SECCION',
        'VIGENCIA',
        'SEXO',
        'FECHA DE NACIMIENTO',
      ],
    );

    text = text
        .replaceAll(RegExp(r'\bDOMICILIO\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bDIRECCION\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bCURP\b', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\bCLAVE\s+DE\s+ELECTOR\b', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\bSECCI[ÓO]N\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bVIGENCIA\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\bSEXO\b', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\bFECHA\s+DE\s+NACIMIENTO\b', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'EMISION.*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'A[ÑN]O\s+DE\s+REGISTRO.*$', caseSensitive: false), '')
        .replaceAll(
          RegExp(r'\b[A-Z]{6}[0-9OILSZBQ]{6}[A-Z][0-9OILSZBQ]{3}\b'),
          '',
        )
        .replaceAll(
          RegExp(r'\b[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}\b'),
          '',
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

      // If a line looks like "ZUMPANGO, MEX." keep it for municipio/estado only.
      final municipioEstado = _parseMunicipioEstado(clean);
      if ((municipioEstado['municipio'] ?? '').isNotEmpty ||
          (municipioEstado['estado'] ?? '').isNotEmpty) {
        continue;
      }

      // Keep CP as a separate field, not inside direccion.
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
      int i = 0;

      while (i < words.length) {
        final currentNorm = _normalizeForCompare(words[i]);
        if (!nameTokens.contains(currentNorm)) {
          filteredWords.add(words[i]);
          i++;
          continue;
        }

        int j = i;
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

    for (int size = words.length ~/ 2; size >= 2; size--) {
      final first = words.sublist(0, size);
      final second = words.sublist(size, size * 2);
      if (_sameWordSequence(first, second)) {
        return _normalizeHumanText(first.join(' '));
      }
    }

    for (int start = 0; start < words.length; start++) {
      for (int size = 2; start + (size * 2) <= words.length; size++) {
        final first = words.sublist(start, start + size);
        final second = words.sublist(start + size, start + (size * 2));
        if (_sameWordSequence(first, second)) {
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

  bool _sameWordSequence(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!_wordsLookEquivalent(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }

  bool _wordsLookEquivalent(String a, String b) {
    final left = _normalizeForCompare(a);
    final right = _normalizeForCompare(b);
    if (left == right) return true;
    if (left.isEmpty || right.isEmpty) return false;

    final maxLength = left.length > right.length ? left.length : right.length;
    if (maxLength <= 3) return false;
    if ((left.length - right.length).abs() > 1) return false;

    return _levenshteinDistance(left, right) <= 1;
  }

  int _levenshteinDistance(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    final previous = List<int>.generate(b.length + 1, (index) => index);
    final current = List<int>.filled(b.length + 1, 0);

    for (int i = 1; i <= a.length; i++) {
      current[0] = i;
      for (int j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          current[j - 1] + 1,
          previous[j] + 1,
          previous[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }

      for (int j = 0; j <= b.length; j++) {
        previous[j] = current[j];
      }
    }

    return previous[b.length];
  }

  List<String> _extractLinesAfterLabel(
    String text,
    String label, {
    required List<String> stopLabels,
    int maxLines = 3,
  }) {
    final lines = _cleanLines(text);
    final labelNorm = _normalizeForCompare(label);
    final stopNorms = stopLabels.map(_normalizeForCompare).toList();

    final result = <String>[];
    bool collecting = false;

    for (final line in lines) {
      final currentNorm = _normalizeForCompare(line);

      if (!collecting) {
        if (currentNorm == labelNorm ||
            currentNorm.startsWith('$labelNorm ') ||
            currentNorm.contains(labelNorm)) {
          collecting = true;

          var inline = line;
          final idx = currentNorm.indexOf(labelNorm);
          if (idx >= 0) {
            inline = line.substring(idx + label.length).trim();
          }

          if (inline.isNotEmpty &&
              !_looksLikeLabel(inline) &&
              !_looksLikeHeaderNoise(inline)) {
            result.add(inline);
          }

          continue;
        }
      } else {
        final shouldStop = stopNorms.any((stop) {
          return currentNorm == stop ||
              currentNorm.startsWith('$stop ') ||
              currentNorm.contains(stop);
        });

        if (shouldStop) {
          break;
        }

        if (!_looksLikeLabel(line) &&
            !_looksLikeHeaderNoise(line) &&
            line.trim().isNotEmpty) {
          result.add(line);
        }

        if (result.length >= maxLines) {
          break;
        }
      }
    }

    return result;
  }

  String _extractClaveElector(String zoneText, String fullText) {
    for (final source in [zoneText, fullText]) {
      final labeledCandidate = _extractCompactTokenAfterLabel(
        source,
        'CLAVE DE ELECTOR',
        minLength: 17,
        maxLength: 19,
      );
      if (labeledCandidate.isNotEmpty) {
        final fixed = _fixClaveElector(labeledCandidate);
        if (_claveElectorExactRegex.hasMatch(fixed)) {
          return fixed;
        }
      }
    }

    final candidates = <String>[
      ..._extractRegexMatches(
        zoneText,
        _claveElectorLooseRegex,
      ),
      ..._extractRegexMatches(
        fullText,
        _claveElectorLooseRegex,
      ),
    ];

    if (candidates.isNotEmpty) {
      return candidates.first;
    }

    final compactCandidates = <String>[
      ..._extractCompactRegexMatches(
        zoneText,
        _claveElectorLooseRegex,
      ),
      ..._extractCompactRegexMatches(
        fullText,
        _claveElectorLooseRegex,
      ),
    ];

    if (compactCandidates.isNotEmpty) {
      for (final candidate in compactCandidates) {
        final fixed = _fixClaveElector(candidate);
        if (_claveElectorExactRegex.hasMatch(fixed)) {
          return fixed;
        }
      }
    }

    final tokenCandidates = <String>[
      ..._extractCompactAlphaNumericCandidates(zoneText, minLength: 17),
      ..._extractCompactAlphaNumericCandidates(fullText, minLength: 17),
    ];

    final bestToken = tokenCandidates.firstWhere(
      (candidate) => _claveElectorLooseRegex.hasMatch(candidate),
      orElse: () => '',
    );

    if (bestToken.isNotEmpty) {
      final fixed = _fixClaveElector(bestToken);
      if (_claveElectorExactRegex.hasMatch(fixed)) {
        return fixed;
      }
    }

    return '';
  }

  String _extractCurp(String zoneText, String fullText) {
    for (final source in [zoneText, fullText]) {
      final labeledCandidate = _extractCompactTokenAfterLabel(
        source,
        'CURP',
        minLength: 18,
        maxLength: 20,
      );
      if (labeledCandidate.isNotEmpty) {
        final fixed = _fixCurp(labeledCandidate);
        if (_curpExactRegex.hasMatch(fixed)) {
          return fixed;
        }
      }
    }

    final candidates = <String>[
      ..._extractRegexMatches(
        zoneText,
        _curpLooseRegex,
      ),
      ..._extractRegexMatches(
        fullText,
        _curpLooseRegex,
      ),
    ];

    if (candidates.isNotEmpty) {
      return candidates.first;
    }

    final compactCandidates = <String>[
      ..._extractCompactRegexMatches(
        zoneText,
        _curpLooseRegex,
      ),
      ..._extractCompactRegexMatches(
        fullText,
        _curpLooseRegex,
      ),
    ];

    if (compactCandidates.isNotEmpty) {
      for (final candidate in compactCandidates) {
        final fixed = _fixCurp(candidate);
        if (_curpExactRegex.hasMatch(fixed)) {
          return fixed;
        }
      }
    }

    final tokenCandidates = <String>[
      ..._extractCompactAlphaNumericCandidates(zoneText, minLength: 18),
      ..._extractCompactAlphaNumericCandidates(fullText, minLength: 18),
    ];

    final bestToken = tokenCandidates.firstWhere(
      (candidate) => _curpLooseRegex.hasMatch(candidate),
      orElse: () => '',
    );

    if (bestToken.isNotEmpty) {
      final fixed = _fixCurp(bestToken);
      if (_curpExactRegex.hasMatch(fixed)) {
        return fixed;
      }
    }

    return '';
  }

  String _extractFechaNacimiento(String zoneText, String fullText) {
    final labeledValue = _extractValueNearLabel(
      fullText,
      'FECHA DE NACIMIENTO',
      fallbackText: zoneText,
    );
    final labeledMatch = RegExp(
      r'\d{2}[\/\.-]\d{2}[\/\.-]\d{4}',
    ).firstMatch(_normalizeText(labeledValue));
    if (labeledMatch != null) {
      return labeledMatch.group(0) ?? '';
    }

    final candidates = <String>[
      ..._extractRegexMatches(
        zoneText,
        RegExp(r'\d{2}[\/\.-]\d{2}[\/\.-]\d{4}'),
      ),
      ..._extractRegexMatches(
        fullText,
        RegExp(r'\d{2}[\/\.-]\d{2}[\/\.-]\d{4}'),
      ),
    ];

    if (candidates.isNotEmpty) {
      return candidates.first;
    }

    return _extractCompactValueNearLabel(
      fullText,
      'FECHA DE NACIMIENTO',
      fallbackText: zoneText,
      maxLength: 12,
    );
  }

  String _extractVigencia(String zoneText, String fullText) {
    final labeledCandidate = _extractCompactTokenAfterLabel(
      fullText,
      'VIGENCIA',
      minLength: 8,
      maxLength: 11,
      allowDash: true,
    );
    if (labeledCandidate.isNotEmpty) {
      return labeledCandidate;
    }

    final candidates = <String>[
      ..._extractRegexMatches(
        zoneText,
        RegExp(r'\d{4}\s*[-\/]\s*\d{4}'),
      ),
      ..._extractRegexMatches(
        fullText,
        RegExp(r'\d{4}\s*[-\/]\s*\d{4}'),
      ),
    ];

    if (candidates.isNotEmpty) {
      return candidates.first;
    }

    return _extractCompactValueNearLabel(
      fullText,
      'VIGENCIA',
      fallbackText: zoneText,
      maxLength: 12,
    );
  }

  String _extractSeccion(String zoneText, String fullText) {
    final labeledToken = _extractCompactTokenAfterLabel(
      fullText,
      'SECCION',
      minLength: 3,
      maxLength: 4,
    );
    if (labeledToken.isNotEmpty) {
      return labeledToken;
    }

    final labeledCandidates = _extractLinesAfterLabel(
      fullText,
      'SECCION',
      stopLabels: const [
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
        'CURP',
        'CLAVE DE ELECTOR',
        'DOMICILIO',
        'NOMBRE',
      ],
      maxLines: 2,
    );

    for (final line in labeledCandidates) {
      final match = RegExp(r'\b\d{3,4}\b').firstMatch(_normalizeText(line));
      if (match != null) {
        final value = match.group(0) ?? '';
        final fixed = _fixSeccion(value);
        if (fixed.length >= 3 && fixed.length <= 4) {
          return fixed;
        }
      }
    }

    final candidates = <String>[
      ..._extractRegexMatches(zoneText, RegExp(r'\b\d{3,4}\b')),
      ..._extractRegexMatches(fullText, RegExp(r'\b\d{3,4}\b')),
    ];

    final filtered = candidates.where((e) {
      final fixed = _fixSeccion(e);
      return fixed.length >= 3 && fixed.length <= 4;
    }).toList();

    if (filtered.isNotEmpty) {
      return filtered.first;
    }

    return _extractCompactValueNearLabel(
      fullText,
      'SECCION',
      fallbackText: zoneText,
      maxLength: 4,
    );
  }

  String _extractSexo(String zoneText, String fullText) {
    final labeledToken = _extractCompactTokenAfterLabel(
      fullText,
      'SEXO',
      minLength: 1,
      maxLength: 1,
    );
    if (labeledToken == 'H' || labeledToken == 'M') {
      return labeledToken;
    }

    final zoneNorm = _normalizeForCompare(zoneText);
    if (zoneNorm.contains('MUJER') || RegExp(r'\bM\b').hasMatch(zoneNorm)) {
      return 'M';
    }
    if (zoneNorm.contains('HOMBRE') || RegExp(r'\bH\b').hasMatch(zoneNorm)) {
      return 'H';
    }

    final fullNorm = _normalizeForCompare(fullText);
    if (fullNorm.contains('MUJER')) return 'M';
    if (fullNorm.contains('HOMBRE')) return 'H';

    return _extractValueNearLabel(
      fullText,
      'SEXO',
      fallbackText: zoneText,
    );
  }

  String _extractCodigoPostal(String zoneText, String fullText) {
    final domicilioLines = _extractLinesAfterLabel(
      fullText,
      'DOMICILIO',
      stopLabels: const [
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
        'AÑO DE REGISTRO',
        'ANO DE REGISTRO',
      ],
      maxLines: 4,
    );

    for (final line in domicilioLines) {
      final cpMatch = RegExp(r'\b\d{5}\b').firstMatch(_normalizeText(line));
      if (cpMatch != null) {
        return cpMatch.group(0) ?? '';
      }
    }

    final candidates = <String>[
      ..._extractRegexMatches(zoneText, RegExp(r'\b\d{5}\b')),
      ..._extractRegexMatches(fullText, RegExp(r'\b\d{5}\b')),
    ];

    if (candidates.isNotEmpty) {
      return candidates.first;
    }

    return '';
  }

  List<String> _extractRegexMatches(String text, RegExp regex) {
    return regex
        .allMatches(_normalizeText(text))
        .map((m) => m.group(0) ?? '')
        .where((e) => e.trim().isNotEmpty)
        .toList();
  }

  List<String> _extractCompactRegexMatches(String text, RegExp regex) {
    final compact = _normalizeText(text).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return regex
        .allMatches(compact)
        .map((m) => m.group(0) ?? '')
        .where((e) => e.trim().isNotEmpty)
        .toList();
  }

  List<String> _extractCompactAlphaNumericCandidates(
    String text, {
    required int minLength,
  }) {
    final compact = _normalizeText(text).replaceAll(RegExp(r'[^A-Z0-9]'), ' ');
    return compact
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length >= minLength)
        .toList();
  }

  String _extractValueNearLabel(
    String fullText,
    String label, {
    String fallbackText = '',
  }) {
    final lines = _extractLinesAfterLabel(
      fullText,
      label,
      stopLabels: const [
        'NOMBRE',
        'DOMICILIO',
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'SECCIÓN',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
      ],
      maxLines: 2,
    );

    if (lines.isNotEmpty) {
      return _normalizeHumanText(lines.join(' '));
    }

    return _normalizeHumanText(fallbackText);
  }

  String _extractCompactTokenAfterLabel(
    String fullText,
    String label, {
    required int minLength,
    required int maxLength,
    bool allowDash = false,
  }) {
    final lineCandidates = _extractLinesAfterLabel(
      fullText,
      label,
      stopLabels: const [
        'NOMBRE',
        'DOMICILIO',
        'CLAVE DE ELECTOR',
        'CURP',
        'SEXO',
        'SECCION',
        'SECCIÃ“N',
        'VIGENCIA',
        'FECHA DE NACIMIENTO',
        'AÃ‘O DE REGISTRO',
        'ANO DE REGISTRO',
      ],
      maxLines: 2,
    );

    for (final line in lineCandidates) {
      final token = _extractCompactTokenFromText(
        _stripLabelFromText(line, label),
        minLength: minLength,
        maxLength: maxLength,
        allowDash: allowDash,
      );
      if (token.isNotEmpty) {
        return token;
      }
    }

    final labeledValue = _extractValueNearLabel(fullText, label);
    if (labeledValue.isEmpty) return '';

    return _extractCompactTokenFromText(
      _stripLabelFromText(labeledValue, label),
      minLength: minLength,
      maxLength: maxLength,
      allowDash: allowDash,
    );
  }

  String _stripLabelFromText(String text, String label) {
    var value = _normalizeText(text);
    final labelNorm = _normalizeForCompare(label);

    value = value.replaceAll(
      RegExp(labelNorm.replaceAll(' ', r'\s*'), caseSensitive: false),
      ' ',
    );
    value = value.replaceAll(
      RegExp(labelNorm.replaceAll(' ', ''), caseSensitive: false),
      ' ',
    );

    if (labelNorm == 'CLAVE DE ELECTOR') {
      value = value.replaceAll(
        RegExp(r'CLAVE\s*DE\s*ELECTOR', caseSensitive: false),
        ' ',
      );
    }
    if (labelNorm == 'CURP') {
      value = value.replaceAll(RegExp(r'\bCURP\b', caseSensitive: false), ' ');
    }

    return _normalizeHumanText(value);
  }

  String _extractCompactTokenFromText(
    String text, {
    required int minLength,
    required int maxLength,
    bool allowDash = false,
  }) {
    final pattern = allowDash
        ? RegExp('[A-Z0-9-]{$minLength,$maxLength}')
        : RegExp('[A-Z0-9]{$minLength,$maxLength}');

    final directMatch = pattern.firstMatch(
      _normalizeText(text).replaceAll(' ', ''),
    );
    if (directMatch != null) {
      return directMatch.group(0) ?? '';
    }

    final normalized = _normalizeText(text);
    final tokenized = normalized
        .replaceAll(allowDash ? RegExp(r'[^A-Z0-9\-]') : RegExp(r'[^A-Z0-9]'), ' ')
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where((token) => token.length >= minLength && token.length <= maxLength)
        .toList();

    if (tokenized.isNotEmpty) {
      return tokenized.first;
    }

    return '';
  }

  String _extractCompactValueNearLabel(
    String fullText,
    String label, {
    String fallbackText = '',
    required int maxLength,
  }) {
    final direct = _extractValueNearLabel(
      fullText,
      label,
      fallbackText: fallbackText,
    );

    final compact = _normalizeHumanText(direct);
    if (compact.isEmpty) return '';
    if (compact.length > maxLength) return '';
    if (compact.contains('\n')) return '';

    return compact;
  }

  Future<Map<String, String>?> _lookupCpData(String codigoPostal) async {
    final cp = _fixCodigoPostal(codigoPostal);
    if (cp.length != 5) return null;

    try {
      final catalog = await _loadCpCatalog();
      for (final row in catalog) {
        final rowCp = _normalizeCpRowValue(
          row['codigoPostal'] ??
              row['cp'] ??
              row['d_codigo'] ??
              row['codigo_postal'],
        );

        if (rowCp == cp) {
          final estado = _normalizeHumanText(
            (row['estado'] ?? row['d_estado'] ?? '').toString(),
          );
          final municipio = _normalizeHumanText(
            (row['municipio'] ?? row['D_mnpio'] ?? row['d_mnpio'] ?? '').toString(),
          );

          if (estado.isEmpty && municipio.isEmpty) {
            continue;
          }

          return {
            'estado': estado,
            'municipio': municipio,
          };
        }
      }
    } catch (e) {
      debugPrint('[OCR] Error buscando CP en catálogo: $e');
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> _loadCpCatalog() async {
    if (_cpCatalogCache != null) {
      return _cpCatalogCache!;
    }

    final raw = await rootBundle.loadString('assets/cp_catalog.json');
    final decoded = jsonDecode(raw);

    if (decoded is List) {
      _cpCatalogCache = decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
      return _cpCatalogCache!;
    }

    if (decoded is Map<String, dynamic>) {
      if (decoded['data'] is List) {
        _cpCatalogCache = (decoded['data'] as List)
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
            .toList();
        return _cpCatalogCache!;
      }
    }

    _cpCatalogCache = [];
    return _cpCatalogCache!;
  }

  String _normalizeCpRowValue(dynamic value) {
    return _onlyDigits((value ?? '').toString());
  }

  String _preferCatalogValue({
    required String? catalogValue,
    required String ocrValue,
  }) {
    final catalog = _normalizeHumanText(catalogValue ?? '');
    final ocr = _normalizeHumanText(ocrValue);

    if (catalog.isNotEmpty) return catalog;
    return ocr;
  }

  Future<void> dispose() async {
    await _recognizer.close();
    await _detector.dispose();
  }
}

class _PreparedOcrImage {
  final List<String> fullPaths;
  final List<String> nameZonePaths;
  final List<String> addressZonePaths;
  final List<String> dataZonePaths;

  _PreparedOcrImage({
    required this.fullPaths,
    required this.nameZonePaths,
    required this.addressZonePaths,
    required this.dataZonePaths,
  });
}
