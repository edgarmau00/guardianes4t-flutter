import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:doc_scan_flutter/doc_scan.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/routes.dart';
import '../../services/ios_native_ine_scanner.dart';
import '../../services/ocr_service.dart';
import '../../services/ocr_validation_service.dart';
import '../../services/web_ocr_parser.dart';

class ScanIneScreen extends StatefulWidget {
  const ScanIneScreen({super.key});

  @override
  State<ScanIneScreen> createState() => _ScanIneScreenState();
}

class _ScanIneScreenState extends State<ScanIneScreen> {
  static const int _qualityCheckMaxWidth = 960;
  static const Duration _ocrTimeout = Duration(seconds: 28);
  static const Duration _iosPreCaptureFocusWait = Duration(milliseconds: 680);
  static const double _iosBlockingBlurThreshold = 3.0;
  static const double _iosWarningBlurThreshold = 4.8;
  static const double _iosOcrCropWidthFactor = 0.78;
  static const double _iosOcrCropHeightFactor = 0.30;

  bool _processing = false;
  bool _scannerOpened = false;
  bool _openingNativeScanner = false;
  String _processingMessage = 'Procesando datos...';
  final ImagePicker _iosImagePicker = ImagePicker();

  CameraController? _iosCameraController;
  bool _iosManualFallbackMode = false;
  bool _iosCameraReady = false;
  bool _iosCameraInitializing = false;
  bool _iosCaptureInProgress = false;
  String _iosHint =
      'Acomoda la INE dentro del recuadro. Manten unos 18 a 26 cm de distancia y toca "Tomar ahora" cuando el texto se vea claro.';

  @override
  void initState() {
    super.initState();

    if (Platform.isIOS) {
      _processingMessage = 'Preparando camara...';
      _processing = false;
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scannerOpened) return;
      _scannerOpened = true;
      _scanWithDocumentScanner();
    });
  }

  @override
  void dispose() {
    _disposeIosCamera();
    super.dispose();
  }

  Future<void> _initializeIosCamera() async {
    if (!Platform.isIOS || _iosCameraInitializing) return;
    if (_iosCameraReady &&
        _iosCameraController != null &&
        _iosCameraController!.value.isInitialized) {
      return;
    }

    _iosCameraInitializing = true;

    try {
      await _disposeIosCamera();

      final cameras = await availableCameras();
      final rearCamera = _selectBestIosRearCamera(cameras);

      final controller = CameraController(
        rearCamera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );

      await controller.initialize();
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (_) {}
      try {
        await _configureIosCamera(controller);
      } catch (_) {}

      _iosCameraController = controller;
      _iosCameraReady = true;

      if (mounted) {
        setState(() {});
      }

    } catch (_) {
      if (!mounted) return;
      setState(() {
        _iosHint = 'No se pudo abrir la camara. Intenta de nuevo.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo inicializar la camara en iPhone.'),
        ),
      );
    } finally {
      _iosCameraInitializing = false;
    }
  }

  Future<void> _activateIosManualFallback([String? snackMessage]) async {
    if (!Platform.isIOS) return;

    if (mounted) {
      setState(() {
        _iosManualFallbackMode = false;
        _processing = false;
        _processingMessage = 'Procesando datos...';
        _iosHint =
            'Se abrira la camara nativa de iPhone. Centra toda la INE y toma la foto cuando el texto se vea nitido.';
      });
    }

    if (snackMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(snackMessage)),
      );
    }

    await _captureWithIosNativeCamera();
  }

  Future<void> _captureWithIosNativeCamera() async {
    if (!Platform.isIOS || _processing || _iosCaptureInProgress) return;

    _iosCaptureInProgress = true;

    try {
      final picked = await _iosImagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 100,
        requestFullMetadata: false,
      );

      if (picked == null) {
        if (mounted) {
          setState(() {
            _processing = false;
            _iosHint =
                'Captura cancelada. Vuelve a abrir la camara cuando tengas la INE lista.';
          });
        }
        return;
      }

      if (!mounted) return;
      setState(() {
        _processing = true;
        _processingMessage = 'Procesando imagen...';
      });

      final success = await _processImagePath(picked.path);
      if (!success && mounted) {
        setState(() {
          _processing = false;
          _iosHint =
              'No se pudo leer bien la INE. Toma otra foto con mejor luz y manteniendo visible toda la credencial.';
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _iosHint = 'No se pudo abrir la camara de iPhone. Intenta de nuevo.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir la camara en iPhone.'),
        ),
      );
    } finally {
      _iosCaptureInProgress = false;
    }
  }

  Future<void> _disposeIosCamera() async {
    final controller = _iosCameraController;
    _iosCameraController = null;
    _iosCameraReady = false;

    if (controller == null) return;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}

    await controller.dispose();
  }

  CameraDescription _selectBestIosRearCamera(List<CameraDescription> cameras) {
    if (cameras.isEmpty) {
      throw StateError('No hay camaras disponibles en el dispositivo.');
    }

    if (!Platform.isIOS) {
      return cameras.first;
    }

    final rearCameras = cameras
        .where((camera) => camera.lensDirection == CameraLensDirection.back)
        .toList();
    if (rearCameras.isEmpty) {
      return cameras.first;
    }

    int score(CameraDescription camera) {
      final name = camera.name.toLowerCase();
      var value = 0;

      if (name.contains('wide')) value += 120;
      if (name.contains('main')) value += 110;
      if (name.contains('back')) value += 80;
      if (name.contains('rear')) value += 70;
      if (name.contains('telephoto')) value -= 130;
      if (name.contains('tele')) value -= 110;
      if (name.contains('ultra')) value -= 180;
      if (name.contains('macro')) value -= 160;
      if (name.contains('depth')) value -= 140;
      if (name.contains('truedepth')) value -= 220;

      if (camera.sensorOrientation == 90) value += 8;
      if (camera.sensorOrientation == 270) value += 4;

      return value;
    }

    rearCameras.sort((a, b) => score(b).compareTo(score(a)));
    return rearCameras.first;
  }

  Future<void> _configureIosCamera(CameraController controller) async {
    try {
      await controller.setFocusMode(FocusMode.auto);
    } catch (_) {}

    try {
      await controller.setExposureMode(ExposureMode.auto);
    } catch (_) {}

    try {
      await controller.setFocusPoint(const Offset(0.5, 0.5));
    } catch (_) {}

    try {
      await controller.setExposurePoint(const Offset(0.5, 0.5));
    } catch (_) {}

    try {
      await controller.setZoomLevel(1.0);
    } catch (_) {}
  }

  Future<void> _prepareIosFocusForCapture(CameraController controller) async {
    await _configureIosCamera(controller);
    await Future.delayed(const Duration(milliseconds: 220));
    await _configureIosCamera(controller);
    await Future.delayed(const Duration(milliseconds: 260));
    await _configureIosCamera(controller);
    await Future.delayed(_iosPreCaptureFocusWait);
  }

  Future<void> _takeSingleAutoPicture() async {
    final controller = _iosCameraController;
    if (!Platform.isIOS ||
        controller == null ||
        !controller.value.isInitialized ||
        _iosCaptureInProgress ||
        _processing) {
      return;
    }

    _iosCaptureInProgress = true;

    try {
      if (!mounted) return;

      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }

      await _prepareIosFocusForCapture(controller);

      if (!controller.value.isInitialized || controller.value.isTakingPicture) {
        throw CameraException(
          'ios_camera_not_ready',
          'La camara aun no esta lista para capturar.',
        );
      }

      setState(() {
        _processing = true;
        _processingMessage = 'Capturando imagen...';
      });

      final image = await controller.takePicture();
      final success = await _processImagePath(image.path);

      if (!success && mounted) {
        setState(() {
          _processing = false;
          _iosHint =
              'No se pudo leer bien. Ajusta la distancia hasta que el texto se vea claro y vuelve a tocar "Tomar ahora".';
        });
        _iosCaptureInProgress = false;
        return;
      }
    } catch (_) {
      try {
        await _iosCameraController?.dispose();
      } catch (_) {}
      _iosCameraController = null;
      _iosCameraReady = false;

      if (mounted) {
        setState(() {
          _processing = false;
          _iosHint = 'No se pudo tomar la foto. Intenta de nuevo.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se pudo tomar la foto en iPhone.'),
          ),
        );
      }

      try {
        await _initializeIosCamera();
      } catch (_) {}
    } finally {
      _iosCaptureInProgress = false;
    }
  }

  Future<_ImageQualityCheck> _validateImageQuality(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        return const _ImageQualityCheck(
          blockingMessage:
              'No se pudo leer bien la imagen. Intenta escanear de nuevo.',
        );
      }

      final sampleImage = decoded.width > _qualityCheckMaxWidth
          ? img.copyResize(decoded, width: _qualityCheckMaxWidth)
          : decoded;

      if (sampleImage.width < 680 || sampleImage.height < 400) {
        return const _ImageQualityCheck(
          blockingMessage:
              'La imagen salio con poca resolucion. Acerca un poco mas la INE.',
        );
      }

      final gray = img.grayscale(img.Image.from(sampleImage));

      double brightnessSum = 0;
      double edgeSum = 0;
      int samples = 0;

      for (int y = 1; y < gray.height - 1; y += 6) {
        for (int x = 1; x < gray.width - 1; x += 6) {
          final center = gray.getPixel(x, y).r.toDouble();
          final right = gray.getPixel(x + 1, y).r.toDouble();
          final bottom = gray.getPixel(x, y + 1).r.toDouble();

          brightnessSum += center;
          edgeSum += (center - right).abs() + (center - bottom).abs();
          samples++;
        }
      }

      if (samples == 0) {
        return const _ImageQualityCheck();
      }

      final avgBrightness = brightnessSum / samples;
      final avgEdge = edgeSum / samples;

      if (avgBrightness < 30) {
        return const _ImageQualityCheck(
          warningMessage:
              'La imagen se ve oscura. Busca mas luz blanca para mejorar la lectura.',
        );
      }

      if (avgBrightness > 248) {
        return const _ImageQualityCheck(
          warningMessage:
              'La imagen tiene mucho brillo o reflejo. Inclina un poco la INE para evitarlo.',
        );
      }

      if (avgEdge < (_iosBlockingBlurThreshold - 0.8)) {
        return const _ImageQualityCheck(
          blockingMessage:
              'La imagen salio borrosa. Aleja un poco el telefono, mantén la INE fija y reintenta.',
        );
      }

      if (avgEdge < _iosWarningBlurThreshold) {
        return const _ImageQualityCheck(
          warningMessage:
              'La imagen aun se ve algo suave. Si falla la lectura, aleja un poco el telefono y evita movimiento.',
        );
      }

      final aspectRatio = sampleImage.width / sampleImage.height;
      if (aspectRatio < 1.0 || aspectRatio > 2.6) {
        return const _ImageQualityCheck(
          warningMessage:
              'La INE parece recortada o mal encuadrada. La lectura podria bajar.',
        );
      }

      return const _ImageQualityCheck();
    } catch (_) {
      return const _ImageQualityCheck();
    }
  }

  Future<void> _scanWithDocumentScanner() async {
    if ((_processing && !Platform.isIOS) || _openingNativeScanner) return;

    if (Platform.isIOS) {
      await _activateIosManualFallback();
      return;
    }

    try {
      setState(() {
        _processing = true;
        _processingMessage = 'Abriendo escaner inteligente...';
      });

      final result = await DocumentScanner.scan(format: DocScanFormat.jpeg);
      if (result == null || result.isEmpty) {
        if (!mounted) return;
        setState(() {
          _processing = false;
        });
        return;
      }

      await _processImagePath(result.first);
    } on DocumentScannerException {
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo escanear el documento. Intenta de nuevo.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al usar el escaner. Intenta de nuevo.'),
        ),
      );
    }
  }

  Future<bool> _processImagePath(
    String imagePath, {
    Map<String, String>? preferredRawResult,
  }) async {
    Map<String, String>? iosPreferredRawResult = preferredRawResult;
    if (Platform.isIOS && iosPreferredRawResult == null && false) {
      try {
        final nativeStill = await IosNativeIneScanner().processCapturedImage(
          imagePath,
        );
        if (nativeStill != null &&
            (nativeStill.rawText.trim().isNotEmpty ||
                nativeStill.structuredData.isNotEmpty)) {
          final nativeRaw = await WebOcrParser().parse(nativeStill.rawText);
          nativeRaw.addAll(nativeStill.structuredData);
          nativeRaw['rawText'] = nativeStill.rawText;
          nativeRaw['processingMode'] = nativeStill.source;
          iosPreferredRawResult = nativeRaw;
        }
      } catch (_) {
        // Si falla el OCR nativo para foto fija, seguimos con el flujo OCR normal.
      }
    }

    final processingMode = (iosPreferredRawResult?['processingMode'] ?? '');
    final isNativeIosScan =
        Platform.isIOS &&
        (processingMode.contains('ios_visionkit_native') ||
            processingMode.contains('ios_vision_still_image'));

    if (!mounted) return false;

    setState(() {
      _processing = true;
      _processingMessage = 'Validando calidad de imagen...';
    });

    final qualityCheck = await _validateImageQuality(imagePath);
    if (qualityCheck.blockingMessage != null) {
      if (Platform.isIOS) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${qualityCheck.blockingMessage!} Continuaremos con la revision manual del OCR.',
              ),
            ),
          );
        }
      } else {
        if (!mounted) return false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(qualityCheck.blockingMessage!)),
        );
        setState(() => _processing = false);
        return false;
      }
    }

    if (qualityCheck.warningMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(qualityCheck.warningMessage!)),
      );
    }

    if (!mounted) return false;

    setState(() {
      _processingMessage = 'Corrigiendo imagen y leyendo datos...';
    });

    final ocr = OcrService();
    final validator = OcrValidationService();
    try {
      Map<String, String> rawResult;
      OcrValidationResult validation;

      if (Platform.isIOS) {
        final iosCandidatePaths = await _prepareIosCapturedImageCandidates(
          imagePath,
        );
        _IosOcrResult? bestResult;

        if (iosPreferredRawResult != null) {
          final preferredValidation = validator.validate(iosPreferredRawResult);
          bestResult = _IosOcrResult(
            rawResult: iosPreferredRawResult,
            validation: preferredValidation,
          );
        }

        if (bestResult == null || !_isIosNativeResultStrong(bestResult.validation)) {
          final refinedResult = await _scanIneWithIosRefinement(
            ocr,
            imagePath,
            candidatePaths: iosCandidatePaths,
          ).timeout(_ocrTimeout);

          if (bestResult == null ||
              _iosValidationScore(refinedResult.validation) >
                  _iosValidationScore(bestResult.validation)) {
            bestResult = refinedResult;
          }
        }

        rawResult = bestResult.rawResult;
        validation = bestResult.validation;
        final finalizedResult = await _finalizeIosResult(
          rawResult: rawResult,
          validation: validation,
          nativeSeed: iosPreferredRawResult,
        );
        rawResult = finalizedResult.rawResult;
        validation = finalizedResult.validation;
      } else {
        rawResult = await ocr.scanIne(imagePath).timeout(_ocrTimeout);
        validation = validator.validate(rawResult);
      }

      final data = Map<String, dynamic>.from(validation.normalizedData);

      data['processingMode'] = rawResult['processingMode'] ?? 'ocr_only';
      data['globalConfidence'] = validation.globalConfidence;

      if (!mounted) return false;

      Navigator.pushReplacementNamed(
        context,
        AppRoutes.ocrReview,
        arguments: {
          ...data,
          'warnings': validation.warnings,
          'confidence': validation.confidence,
          'imagePath': imagePath,
          'rawText': rawResult['rawText'] ?? '',
          'globalConfidence': validation.globalConfidence,
        },
      );
      return true;
    } catch (_) {
      if (isNativeIosScan && iosPreferredRawResult != null && mounted) {
        final fallbackValidation = validator.validate(iosPreferredRawResult);
        final data = Map<String, dynamic>.from(fallbackValidation.normalizedData);

        data['processingMode'] =
            iosPreferredRawResult['processingMode'] ?? 'ios_visionkit_native';
        data['globalConfidence'] = fallbackValidation.globalConfidence;

        Navigator.pushReplacementNamed(
          context,
          AppRoutes.ocrReview,
          arguments: {
            ...data,
            'warnings': fallbackValidation.warnings,
            'confidence': fallbackValidation.confidence,
            'imagePath': imagePath,
            'rawText': iosPreferredRawResult['rawText'] ?? '',
            'globalConfidence': fallbackValidation.globalConfidence,
          },
        );
        return true;
      }

      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo completar la lectura. Intenta de nuevo con una foto mas estable.',
          ),
        ),
      );
      setState(() => _processing = false);
      return false;
    } finally {
      await ocr.dispose();
      if (mounted && !Platform.isIOS) {
        setState(() => _processing = false);
      }
    }
  }

  Future<_IosOcrResult> _scanIneWithIosRefinement(
    OcrService ocr,
    String imagePath,
    {List<String> candidatePaths = const <String>[]}
  ) async {
    final primaryRaw = await ocr.scanIne(imagePath);
    final primaryValidation = OcrValidationService().validate(primaryRaw);
    var bestResult = _IosOcrResult(
      rawResult: primaryRaw,
      validation: primaryValidation,
    );
    var bestImagePath = imagePath;

    if (!_shouldRetryIosOcr(primaryValidation)) {
      return bestResult;
    }

    if (mounted) {
      setState(() {
        _processingMessage = 'Refinando lectura para iPhone...';
      });
    }

    for (final candidatePath in candidatePaths) {
      if (candidatePath == imagePath) continue;

      try {
        final candidateRaw = await ocr.scanIne(candidatePath);
        final candidateValidation = OcrValidationService().validate(candidateRaw);

        if (_iosValidationScore(candidateValidation) >
            _iosValidationScore(bestResult.validation)) {
          bestResult = _IosOcrResult(
            rawResult: candidateRaw,
            validation: candidateValidation,
          );
          bestImagePath = candidatePath;
        }
      } catch (_) {
        // Si una variante falla, seguimos con la mejor disponible.
      }
    }

    final enhancedPath = await _createIosEnhancedImage(bestImagePath);
    if (enhancedPath == null) {
      return bestResult;
    }

    try {
      final refinedRaw = await ocr.scanIne(enhancedPath);
      final refinedValidation = OcrValidationService().validate(refinedRaw);

      if (_iosValidationScore(refinedValidation) >
          _iosValidationScore(bestResult.validation)) {
        return _IosOcrResult(
          rawResult: refinedRaw,
          validation: refinedValidation,
        );
      }
    } catch (_) {
      // Si el refinado falla, conservamos el mejor resultado previo.
    }

    try {
      final regionRecovered = await _recoverIosFieldsFromRegions(
        ocr,
        enhancedPath,
        bestResult.rawResult,
      );
      final regionValidation = OcrValidationService().validate(regionRecovered);

      if (_iosValidationScore(regionValidation) >=
          _iosValidationScore(bestResult.validation)) {
        bestResult = _IosOcrResult(
          rawResult: regionRecovered,
          validation: regionValidation,
        );
      }
    } catch (_) {
      // Si la lectura por zonas falla, mantenemos el mejor resultado vigente.
    }

    return bestResult;
  }

  bool _shouldRetryIosOcr(OcrValidationResult validation) {
    final normalized = validation.normalizedData;
    final clave = (normalized['claveElectoral'] ?? '').trim();
    final curp = (normalized['curp'] ?? '').trim();
    final direccion = (normalized['direccion'] ?? '').trim();
    final nombre = (normalized['nombre'] ?? '').trim();
    final apellidoPaterno = (normalized['apellidoPaterno'] ?? '').trim();
    final apellidoMaterno = (normalized['apellidoMaterno'] ?? '').trim();
    final fechaNacimiento = (normalized['fechaNacimiento'] ?? '').trim();
    final seccionElectoral = (normalized['seccionElectoral'] ?? '').trim();

    if (validation.globalConfidence < 0.94) return true;
    if (clave.length < 18 || curp.length < 18) return true;
    if (direccion.length < 24) return true;
    if (nombre.length < 3) return true;
    if (apellidoPaterno.length < 3) return true;
    if (apellidoMaterno.length < 3) return true;
    if (fechaNacimiento.length < 8) return true;
    if (seccionElectoral.length < 3) return true;
    if ((validation.confidence['claveElectoral'] ?? 0) < 0.96) return true;
    if ((validation.confidence['curp'] ?? 0) < 0.96) return true;
    if ((validation.confidence['direccion'] ?? 0) < 0.86) return true;
    if ((validation.confidence['fechaNacimiento'] ?? 0) < 0.90) return true;
    if ((validation.confidence['seccionElectoral'] ?? 0) < 0.88) return true;
    return false;
  }

  bool _isIosNativeResultStrong(OcrValidationResult validation) {
    final normalized = validation.normalizedData;
    final clave = (normalized['claveElectoral'] ?? '').trim();
    final curp = (normalized['curp'] ?? '').trim();
    final direccion = (normalized['direccion'] ?? '').trim();
    final nombre = (normalized['nombre'] ?? '').trim();
    final apellidoPaterno = (normalized['apellidoPaterno'] ?? '').trim();
    final apellidoMaterno = (normalized['apellidoMaterno'] ?? '').trim();
    final fechaNacimiento = (normalized['fechaNacimiento'] ?? '').trim();

    if (validation.globalConfidence < 0.92) return false;
    if (clave.length < 18) return false;
    if (curp.length < 18) return false;
    if (direccion.length < 24) return false;
    if (nombre.length < 3) return false;
    if (apellidoPaterno.length < 3) return false;
    if (apellidoMaterno.length < 3) return false;
    if (fechaNacimiento.length < 8) return false;
    if ((validation.confidence['claveElectoral'] ?? 0) < 0.94) return false;
    if ((validation.confidence['curp'] ?? 0) < 0.94) return false;
    if ((validation.confidence['direccion'] ?? 0) < 0.82) return false;
    if ((validation.confidence['fechaNacimiento'] ?? 0) < 0.88) return false;
    return true;
  }

  double _iosValidationScore(OcrValidationResult validation) {
    return validation.globalConfidence * 10 +
        (validation.confidence['claveElectoral'] ?? 0.0) * 6 +
        (validation.confidence['curp'] ?? 0.0) * 6 +
        (validation.confidence['direccion'] ?? 0.0) * 4 +
        (validation.confidence['nombre'] ?? 0.0) * 3 +
        (validation.confidence['apellidoPaterno'] ?? 0.0) * 3 +
        (validation.confidence['apellidoMaterno'] ?? 0.0) * 2.5 +
        (validation.confidence['fechaNacimiento'] ?? 0.0) * 3 +
        (validation.confidence['vigencia'] ?? 0.0) * 2.5 +
        (validation.confidence['seccionElectoral'] ?? 0.0) * 2;
  }

  Future<_IosOcrResult> _finalizeIosResult({
    required Map<String, String> rawResult,
    required OcrValidationResult validation,
    Map<String, String>? nativeSeed,
  }) async {
    final merged = <String, String>{};

    void mergeSource(Map<String, String>? source) {
      if (source == null) return;
      for (final entry in source.entries) {
        final value = entry.value.trim();
        if (value.isNotEmpty) {
          merged[entry.key] = value;
        }
      }
    }

    mergeSource(rawResult);
    mergeSource(nativeSeed);

    final rawText = [
      rawResult['rawText'] ?? '',
      nativeSeed?['rawText'] ?? '',
    ].where((value) => value.trim().isNotEmpty).join('\n');

    final reparsed = rawText.trim().isEmpty
        ? <String, String>{}
        : await WebOcrParser().parse(rawText);
    mergeSource(reparsed);

    _repairIosNameFields(merged, rawText);
    _repairIosAddressFields(merged, rawText);
    _repairIosIdentityFields(merged, rawText);

    if (rawText.trim().isNotEmpty) {
      merged['rawText'] = rawText.trim();
    }
    merged['processingMode'] =
        merged['processingMode'] ?? rawResult['processingMode'] ?? 'ocr_only';

    final finalizedValidation = OcrValidationService().validate(merged);
    final finalizedRaw = Map<String, String>.from(merged)
      ..addAll(finalizedValidation.normalizedData);

    return _IosOcrResult(
      rawResult: finalizedRaw,
      validation: finalizedValidation,
    );
  }

  void _repairIosNameFields(Map<String, String> data, String rawText) {
    final currentNombre = (data['nombre'] ?? '').trim();
    final currentPaterno = (data['apellidoPaterno'] ?? '').trim();
    final currentMaterno = (data['apellidoMaterno'] ?? '').trim();

    if (currentNombre.isNotEmpty &&
        currentPaterno.isNotEmpty &&
        currentMaterno.isNotEmpty) {
      return;
    }

    final upperText = _normalizeIosOcrText(rawText);
    final nombreBlock = RegExp(
      r'NOMBRE\s+([A-ZÑ.\s]+?)\s+DOMICILIO',
      dotAll: true,
    ).firstMatch(upperText);

    final extracted = (nombreBlock?.group(1) ?? data['nombre'] ?? '').trim();
    final cleanedExtracted = _cleanIosPersonText(extracted);

    if (cleanedExtracted.isEmpty) return;

    final tokens = cleanedExtracted
        .split(RegExp(r'\s+'))
        .map((token) => token.trim())
        .where(
          (token) =>
              token.isNotEmpty &&
              token.length > 1 &&
              !RegExp(r'^\d+$').hasMatch(token),
        )
        .toList();

    if (tokens.length < 3) {
      if (currentNombre.isEmpty) {
        data['nombre'] = cleanedExtracted;
      }
      return;
    }

    if (currentPaterno.isEmpty) {
      data['apellidoPaterno'] = tokens[0];
    }
    if (currentMaterno.isEmpty) {
      data['apellidoMaterno'] = tokens[1];
    }
    if (currentNombre.isEmpty) {
      data['nombre'] = tokens.sublist(2).join(' ');
    }

    final rebuilt = [
      data['apellidoPaterno'] ?? '',
      data['apellidoMaterno'] ?? '',
      data['nombre'] ?? '',
    ].where((value) => value.trim().isNotEmpty).join(' ').trim();

    if (rebuilt.isNotEmpty) {
      final rebuiltTokens = _cleanIosPersonText(rebuilt)
          .split(RegExp(r'\s+'))
          .where((token) => token.trim().isNotEmpty)
          .toList();
      if (rebuiltTokens.length >= 3) {
        data['apellidoPaterno'] = rebuiltTokens[0];
        data['apellidoMaterno'] = rebuiltTokens[1];
        data['nombre'] = rebuiltTokens.sublist(2).join(' ');
      }
    }
  }

  void _repairIosAddressFields(Map<String, String> data, String rawText) {
    final currentAddress = (data['direccion'] ?? '').trim();
    final currentMunicipio = (data['municipio'] ?? '').trim();
    final currentEstado = (data['estado'] ?? '').trim();
    final currentPostalCode = (data['codigoPostal'] ?? '').trim();

    final upperText = _normalizeIosOcrText(rawText);
    final domicilioMatch = RegExp(
      r'DOMICILIO\s+(.+?)\s+CLAVE\s+DE\s+ELECTOR',
      dotAll: true,
    ).firstMatch(upperText);

    if (currentAddress.isEmpty && domicilioMatch != null) {
      data['direccion'] = _cleanIosAddressText(domicilioMatch.group(1)!);
    }

    final addressSource = _cleanIosAddressText((data['direccion'] ?? '').trim());
    if (addressSource.isEmpty) return;

    data['direccion'] = addressSource;

    final postalMatch = RegExp(r'\b(\d{5})\b').firstMatch(addressSource);
    if (currentPostalCode.isEmpty && postalMatch != null) {
      data['codigoPostal'] = postalMatch.group(1)!;
    }

    final municipalityStateMatch = RegExp(
      r'([A-ZÑ\s]+),\s*([A-ZÑ.]+)\.?\s*(\d{5})?$',
    ).firstMatch(addressSource.toUpperCase());

    if (municipalityStateMatch != null) {
      if (currentMunicipio.isEmpty) {
        data['municipio'] =
            _cleanIosAddressToken(municipalityStateMatch.group(1)!);
      }
      if (currentEstado.isEmpty) {
        data['estado'] =
            _cleanIosAddressToken(municipalityStateMatch.group(2)!);
      }
      if (currentPostalCode.isEmpty && municipalityStateMatch.group(3) != null) {
        data['codigoPostal'] = municipalityStateMatch.group(3)!.trim();
      }
    }
  }

  void _repairIosIdentityFields(Map<String, String> data, String rawText) {
    final upperText = _normalizeIosOcrText(rawText);

    void fillIfEmpty(String key, RegExp pattern) {
      final current = (data[key] ?? '').trim();
      if (current.isNotEmpty) return;
      final match = pattern.firstMatch(upperText);
      if (match != null && match.groupCount >= 1) {
        final value = match.group(1)?.trim() ?? '';
        if (value.isNotEmpty) {
          data[key] = value;
        }
      }
    }

    fillIfEmpty(
      'claveElectoral',
      RegExp(r'CLAVE\s+DE\s+ELECTOR\s+([A-Z0-9]{16,20})'),
    );
    fillIfEmpty(
      'curp',
      RegExp(r'\b([A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2})\b'),
    );
    fillIfEmpty(
      'fechaNacimiento',
      RegExp(r'(\d{2}/\d{2}/\d{4})'),
    );
    fillIfEmpty(
      'vigencia',
      RegExp(r'VIGENCIA\s+([0-9]{4}\s*-\s*[0-9]{4})'),
    );
    fillIfEmpty(
      'seccionElectoral',
      RegExp(r'SECCI[OÓ]N\s+([0-9]{3,4})'),
    );
    fillIfEmpty(
      'sexo',
      RegExp(r'SEXO\s+([HM])'),
    );

    final normalizedClave =
        _normalizeIosClaveElectoral(data['claveElectoral'] ?? '', upperText);
    if (normalizedClave.isNotEmpty) {
      data['claveElectoral'] = normalizedClave;
    }

    final normalizedCurp = _normalizeIosCurp(data['curp'] ?? '', upperText);
    if (normalizedCurp.isNotEmpty) {
      data['curp'] = normalizedCurp;
    }

    final normalizedBirthDate = _normalizeIosBirthDate(
      data['fechaNacimiento'] ?? '',
      upperText,
    );
    if (normalizedBirthDate.isNotEmpty) {
      data['fechaNacimiento'] = normalizedBirthDate;
    }

    final normalizedSection =
        _normalizeIosSection(data['seccionElectoral'] ?? '', upperText);
    if (normalizedSection.isNotEmpty) {
      data['seccionElectoral'] = normalizedSection;
    }

    final normalizedValidity =
        _normalizeIosValidity(data['vigencia'] ?? '', upperText);
    if (normalizedValidity.isNotEmpty) {
      data['vigencia'] = normalizedValidity;
    }

    final normalizedSexo = _normalizeIosSexo(data['sexo'] ?? '', upperText);
    if (normalizedSexo.isNotEmpty) {
      data['sexo'] = normalizedSexo;
    }

    if ((data['claveElector'] ?? '').trim().isEmpty &&
        (data['claveElectoral'] ?? '').trim().isNotEmpty) {
      data['claveElector'] = data['claveElectoral']!;
    }
    if ((data['seccion'] ?? '').trim().isEmpty &&
        (data['seccionElectoral'] ?? '').trim().isNotEmpty) {
      data['seccion'] = data['seccionElectoral']!;
    }
  }

  String _normalizeIosOcrText(String value) {
    return value
        .toUpperCase()
        .replaceAll('\r', ' ')
        .replaceAll('Ã‘', 'Ñ')
        .replaceAll('Ã“', 'Ó')
        .replaceAll('Ã‰', 'É')
        .replaceAll('Ã', 'Á')
        .replaceAll('Ãš', 'Ú')
        .replaceAll('Ã', 'Í')
        .replaceAll('|', 'I')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanIosPersonText(String value) {
    return _normalizeIosOcrText(value)
        .replaceAll(RegExp(r'[^A-ZÑ\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanIosAddressToken(String value) {
    return _normalizeIosOcrText(value)
        .replaceAll(RegExp(r'[^A-ZÑ\s.]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _cleanIosAddressText(String value) {
    return _normalizeIosOcrText(value)
        .replaceAll(RegExp(r'\bDOMICILIO\b'), ' ')
        .replaceAll(RegExp(r'\bCLAVE\s+DE\s+ELECTOR\b.*$'), ' ')
        .replaceAll(RegExp(r'[^A-Z0-9Ñ\s,./-]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeIosClaveElectoral(String current, String rawText) {
    final currentCompact =
        _normalizeIosOcrText(current).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (currentCompact.length >= 18) {
      return currentCompact.substring(0, 18);
    }

    final rawCandidates = RegExp(r'[A-Z0-9]{18,20}')
        .allMatches(rawText)
        .map((match) => match.group(0) ?? '')
        .map((value) => value.replaceAll(RegExp(r'[^A-Z0-9]'), ''))
        .where((value) => value.length >= 18)
        .toList();

    if (rawCandidates.isEmpty) return currentCompact;
    rawCandidates.sort((a, b) => b.length.compareTo(a.length));
    return rawCandidates.first.substring(0, 18);
  }

  String _normalizeIosCurp(String current, String rawText) {
    final currentCompact =
        _normalizeIosOcrText(current).replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final currentMatch = RegExp(
      r'[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}',
    ).firstMatch(currentCompact);
    if (currentMatch != null) {
      return currentMatch.group(0) ?? currentCompact;
    }

    final rawMatch = RegExp(
      r'[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}',
    ).firstMatch(rawText.replaceAll(RegExp(r'[^A-Z0-9]'), ''));
    return rawMatch?.group(0) ?? currentCompact;
  }

  String _normalizeIosBirthDate(String current, String rawText) {
    final currentMatch = RegExp(r'(\d{2})/(\d{2})/(\d{4})').firstMatch(current);
    if (currentMatch != null) {
      return '${currentMatch.group(1)}/${currentMatch.group(2)}/${currentMatch.group(3)}';
    }

    final compact = rawText.replaceAll(RegExp(r'[^0-9/]'), ' ');
    final rawMatch = RegExp(r'(\d{2})/(\d{2})/(\d{4})').firstMatch(compact);
    if (rawMatch != null) {
      return '${rawMatch.group(1)}/${rawMatch.group(2)}/${rawMatch.group(3)}';
    }

    final digits = rawText.replaceAll(RegExp(r'[^0-9]'), '');
    final eightMatch = RegExp(r'(\d{2})(\d{2})(\d{4})').firstMatch(digits);
    if (eightMatch != null) {
      return '${eightMatch.group(1)}/${eightMatch.group(2)}/${eightMatch.group(3)}';
    }
    return current.trim();
  }

  String _normalizeIosSection(String current, String rawText) {
    final currentDigits = current.replaceAll(RegExp(r'[^0-9]'), '');
    if (currentDigits.length >= 4) {
      return currentDigits.substring(0, 4);
    }

    final sectionMatch = RegExp(r'SECCI[OÓ]N\s*([0-9]{3,4})').firstMatch(rawText);
    if (sectionMatch != null) {
      return sectionMatch.group(1) ?? currentDigits;
    }

    final candidates = RegExp(r'\b[0-9]{4}\b')
        .allMatches(rawText)
        .map((match) => match.group(0) ?? '')
        .toList();
    if (candidates.isNotEmpty) {
      return candidates.first;
    }
    return currentDigits;
  }

  String _normalizeIosValidity(String current, String rawText) {
    final currentMatch =
        RegExp(r'((?:19|20)\d{2})\s*-\s*((?:19|20)\d{2})').firstMatch(current);
    if (currentMatch != null) {
      return '${currentMatch.group(1)}-${currentMatch.group(2)}';
    }

    final rawMatch =
        RegExp(r'((?:19|20)\d{2})\s*-\s*((?:19|20)\d{2})').firstMatch(rawText);
    if (rawMatch != null) {
      return '${rawMatch.group(1)}-${rawMatch.group(2)}';
    }

    final years = RegExp(r'(?:19|20)\d{2}')
        .allMatches(rawText)
        .map((match) => match.group(0) ?? '')
        .toList();
    if (years.length >= 2) {
      return '${years[0]}-${years[1]}';
    }
    return current.trim();
  }

  String _normalizeIosSexo(String current, String rawText) {
    final currentUpper = _normalizeIosOcrText(current);
    if (currentUpper == 'H' || currentUpper == 'M') {
      return currentUpper;
    }

    final match = RegExp(r'\bSEXO\s*([HM])\b').firstMatch(rawText) ??
        RegExp(r'\b([HM])\b').firstMatch(rawText);
    return match?.group(1) ?? currentUpper;
  }

  Future<String?> _createIosEnhancedImage(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      var working = img.bakeOrientation(decoded);
      if (working.width > 3000) {
        working = img.copyResize(working, width: 3000);
      } else if (working.width < 2800) {
        working = img.copyResize(working, width: 2800);
      }

      final normalized = img.adjustColor(
        working,
        contrast: 1.26,
        brightness: 0.02,
        gamma: 0.94,
        saturation: 1.0,
      );
      final sharpened = img.convolution(
        normalized,
        filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
      );
      final gray = img.grayscale(img.Image.from(sharpened));
      final enhanced = img.adjustColor(
        gray,
        contrast: 1.58,
        brightness: 0.01,
        gamma: 0.88,
      );

      final tempDir = await getTemporaryDirectory();
      final refinedPath = p.join(
        tempDir.path,
        'ios_ocr_refined_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );

      await File(refinedPath).writeAsBytes(
        img.encodeJpg(enhanced, quality: 96),
      );

      return refinedPath;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, String>> _recoverIosFieldsFromRegions(
    OcrService ocr,
    String imagePath,
    Map<String, String> baseRaw,
  ) async {
    if (!Platform.isIOS) return baseRaw;

    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return baseRaw;

    var working = img.bakeOrientation(decoded);
    if (working.width < 3200) {
      working = img.copyResize(working, width: 3200);
    } else if (working.width > 3600) {
      working = img.copyResize(working, width: 3600);
    }

    final merged = Map<String, String>.from(baseRaw);
    final collectedRawTexts = <String>[
      if ((baseRaw['rawText'] ?? '').trim().isNotEmpty) baseRaw['rawText']!.trim(),
    ];
    final tempDir = await getTemporaryDirectory();

    final regionVariants =
        <String, List<({String id, double x, double y, double w, double h})>>{
      'nombreBloque': [
        (id: 'name_main', x: 0.29, y: 0.16, w: 0.39, h: 0.24),
        (id: 'name_tight', x: 0.31, y: 0.17, w: 0.35, h: 0.21),
        (id: 'name_wide', x: 0.28, y: 0.15, w: 0.43, h: 0.25),
      ],
      'direccion': [
        (id: 'address_main', x: 0.29, y: 0.36, w: 0.47, h: 0.20),
        (id: 'address_tight', x: 0.30, y: 0.38, w: 0.44, h: 0.17),
        (id: 'address_wide', x: 0.27, y: 0.35, w: 0.51, h: 0.21),
      ],
      'claveElectoral': [
        (id: 'clave_main', x: 0.29, y: 0.52, w: 0.58, h: 0.09),
        (id: 'clave_tight', x: 0.33, y: 0.53, w: 0.52, h: 0.08),
        (id: 'clave_right', x: 0.43, y: 0.52, w: 0.43, h: 0.09),
      ],
      'curp': [
        (id: 'curp_main', x: 0.29, y: 0.59, w: 0.49, h: 0.09),
        (id: 'curp_tight', x: 0.31, y: 0.60, w: 0.45, h: 0.08),
        (id: 'curp_wide', x: 0.27, y: 0.58, w: 0.54, h: 0.10),
      ],
      'fechaNacimiento': [
        (id: 'birth_main', x: 0.29, y: 0.69, w: 0.29, h: 0.10),
        (id: 'birth_tight', x: 0.31, y: 0.70, w: 0.24, h: 0.08),
      ],
      'seccionElectoral': [
        (id: 'section_main', x: 0.56, y: 0.68, w: 0.14, h: 0.10),
        (id: 'section_tight', x: 0.57, y: 0.70, w: 0.12, h: 0.08),
      ],
      'vigencia': [
        (id: 'vigencia_main', x: 0.66, y: 0.67, w: 0.20, h: 0.11),
        (id: 'vigencia_tight', x: 0.68, y: 0.69, w: 0.17, h: 0.09),
      ],
      'sexo': [
        (id: 'sexo_main', x: 0.76, y: 0.15, w: 0.15, h: 0.09),
        (id: 'sexo_tight', x: 0.79, y: 0.16, w: 0.10, h: 0.07),
      ],
      'metaDerecha': [
        (id: 'meta_right_main', x: 0.55, y: 0.50, w: 0.33, h: 0.30),
        (id: 'meta_right_tight', x: 0.59, y: 0.54, w: 0.25, h: 0.24),
      ],
    };

    for (final entry in regionVariants.entries) {
      final regionKey = entry.key;
      Map<String, String>? bestRegionRaw;
      String bestRegionText = '';
      double bestScore = double.negativeInfinity;

      for (int i = 0; i < entry.value.length; i++) {
        final region = entry.value[i];
        final crop = _cropIosNormalizedRegion(
          working,
          x: region.x,
          y: region.y,
          widthFactor: region.w,
          heightFactor: region.h,
        );
        if (crop == null) continue;

        final enhanced = _enhanceIosTextRegion(crop, regionKey);
        final cropPath = p.join(
          tempDir.path,
          'ios_region_${region.id}_${DateTime.now().microsecondsSinceEpoch}_$i.jpg',
        );
        await File(cropPath).writeAsBytes(img.encodeJpg(enhanced, quality: 98));

        try {
          final regionRaw = await ocr.scanIne(cropPath);
          final regionText = (regionRaw['rawText'] ?? '').trim();
          if (regionText.isEmpty && regionRaw.isEmpty) continue;

          final score = _scoreIosRegionCandidate(regionKey, regionRaw, regionText);
          if (score > bestScore) {
            bestScore = score;
            bestRegionRaw = regionRaw;
            bestRegionText = regionText;
          }
        } catch (_) {
          // Una zona fallida no debe romper el resto del rescate.
        }
      }

      if (bestRegionRaw == null) continue;
      if (bestRegionText.isNotEmpty) {
        collectedRawTexts.add(bestRegionText);
      }

      _mergeIosRegionResult(merged, regionKey, bestRegionRaw, bestRegionText);
      if (regionKey == 'metaDerecha') {
        _mergeIosRegionResult(
          merged,
          'fechaNacimiento',
          bestRegionRaw,
          bestRegionText,
        );
        _mergeIosRegionResult(
          merged,
          'seccionElectoral',
          bestRegionRaw,
          bestRegionText,
        );
        _mergeIosRegionResult(merged, 'vigencia', bestRegionRaw, bestRegionText);
        _mergeIosRegionResult(merged, 'sexo', bestRegionRaw, bestRegionText);
      }
    }

    final mergedRawText = collectedRawTexts
        .where((value) => value.trim().isNotEmpty)
        .join('\n');
    if (mergedRawText.trim().isNotEmpty) {
      merged['rawText'] = mergedRawText.trim();
    }
    merged['processingMode'] =
        merged['processingMode'] ?? 'ios_manual_region_mix';

    _repairIosNameFields(merged, merged['rawText'] ?? '');
    _repairIosAddressFields(merged, merged['rawText'] ?? '');
    _repairIosIdentityFields(merged, merged['rawText'] ?? '');

    return merged;
  }

  double _scoreIosRegionCandidate(
    String regionKey,
    Map<String, String> regionRaw,
    String regionText,
  ) {
    final upperText = regionText.toUpperCase().replaceAll('\r', ' ').trim();
    final compactText = upperText.replaceAll(RegExp(r'\s+'), ' ');

    double base = compactText.length * 0.02;

    bool has(RegExp pattern) => pattern.hasMatch(compactText);

    switch (regionKey) {
      case 'nombreBloque':
        final nonNoiseLines = regionText
            .split(RegExp(r'[\r\n]+'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .where((line) => !line.toUpperCase().contains('NOMBRE'))
            .where((line) => !line.toUpperCase().contains('SEXO'))
            .toList();
        base += nonNoiseLines.length * 2.5;
        if (nonNoiseLines.length >= 3) base += 10;
        break;
      case 'direccion':
        if (compactText.contains('DOMICILIO')) base += 4;
        if (compactText.contains('MEX')) base += 2;
        if (compactText.length >= 32) base += 10;
        if (RegExp(r'\d{3,5}').hasMatch(compactText)) base += 3;
        break;
      case 'claveElectoral':
        if (has(RegExp(r'[A-Z0-9]{18}'))) base += 20;
        if (has(RegExp(r'CLAVE\s+DE\s+ELECTOR'))) base += 5;
        break;
      case 'curp':
        if (has(RegExp(r'[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}'))) {
          base += 22;
        }
        if (compactText.contains('CURP')) base += 5;
        break;
      case 'fechaNacimiento':
        if (has(RegExp(r'\d{2}/\d{2}/\d{4}'))) base += 16;
        if (compactText.contains('FECHA')) base += 4;
        break;
      case 'seccionElectoral':
        if (has(RegExp(r'\b\d{4}\b'))) base += 12;
        if (compactText.contains('SECCI')) base += 4;
        break;
      case 'vigencia':
        if (has(RegExp(r'\b(19|20)\d{2}\s*-\s*(19|20)\d{2}\b'))) base += 18;
        if (compactText.contains('VIGENCIA')) base += 4;
        break;
      case 'sexo':
        if (has(RegExp(r'\bSEXO\s*[HM]\b')) || has(RegExp(r'\b[HM]\b'))) {
          base += 14;
        }
        break;
      case 'metaDerecha':
        if (has(RegExp(r'\b(19|20)\d{2}\s*-\s*(19|20)\d{2}\b'))) base += 12;
        if (has(RegExp(r'\b\d{2}/\d{2}/\d{4}\b'))) base += 8;
        if (has(RegExp(r'\b\d{4}\b'))) base += 6;
        if (has(RegExp(r'\bSEXO\s*[HM]\b')) || has(RegExp(r'\b[HM]\b'))) {
          base += 5;
        }
        break;
    }

    for (final entry in regionRaw.entries) {
      if (entry.value.trim().isNotEmpty) {
        base += 0.8;
      }
    }

    return base;
  }

  img.Image? _cropIosNormalizedRegion(
    img.Image source, {
    required double x,
    required double y,
    required double widthFactor,
    required double heightFactor,
  }) {
    final left = (source.width * x).round().clamp(0, source.width - 1);
    final top = (source.height * y).round().clamp(0, source.height - 1);
    final width = (source.width * widthFactor).round();
    final height = (source.height * heightFactor).round();
    final safeWidth = math.min(width, source.width - left);
    final safeHeight = math.min(height, source.height - top);

    if (safeWidth < 220 || safeHeight < 90) return null;

    return img.copyCrop(
      source,
      x: left,
      y: top,
      width: safeWidth,
      height: safeHeight,
    );
  }

  img.Image _enhanceIosTextRegion(img.Image source, String regionKey) {
    var working = source.width < 2400
        ? img.copyResize(source, width: 2400)
        : source.width > 2800
            ? img.copyResize(source, width: 2800)
            : source;

    final highDensityRegion = <String>{
      'claveElectoral',
      'curp',
      'fechaNacimiento',
      'seccionElectoral',
      'vigencia',
      'sexo',
    }.contains(regionKey);

    working = img.adjustColor(
      working,
      contrast: highDensityRegion ? 1.62 : 1.44,
      brightness: highDensityRegion ? -0.01 : 0.01,
      gamma: highDensityRegion ? 0.86 : 0.90,
      saturation: 1.0,
    );
    working = img.convolution(
      working,
      filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
    );

    final gray = img.grayscale(img.Image.from(working));
    return img.adjustColor(
      gray,
      contrast: highDensityRegion ? 1.78 : 1.56,
      brightness: 0.0,
      gamma: highDensityRegion ? 0.82 : 0.87,
    );
  }

  void _mergeIosRegionResult(
    Map<String, String> merged,
    String regionKey,
    Map<String, String> regionRaw,
    String regionText,
  ) {
    final upperText = regionText.toUpperCase().replaceAll('\r', ' ');

    String? extract(RegExp pattern) {
      final match = pattern.firstMatch(upperText);
      final value = match?.group(1)?.trim() ?? '';
      return value.isEmpty ? null : value;
    }

    switch (regionKey) {
      case 'nombreBloque':
        final cleanedLines = regionText
            .split(RegExp(r'[\r\n]+'))
            .map((line) => line.trim().toUpperCase())
            .where((line) => line.isNotEmpty)
            .where((line) => !line.contains('NOMBRE'))
            .where((line) => !line.contains('SEXO'))
            .toList();
        if (cleanedLines.isNotEmpty) {
          if ((merged['apellidoPaterno'] ?? '').trim().isEmpty &&
              cleanedLines.isNotEmpty) {
            merged['apellidoPaterno'] = cleanedLines[0];
          }
          if ((merged['apellidoMaterno'] ?? '').trim().isEmpty &&
              cleanedLines.length > 1) {
            merged['apellidoMaterno'] = cleanedLines[1];
          }
          if ((merged['nombre'] ?? '').trim().isEmpty && cleanedLines.length > 2) {
            merged['nombre'] = cleanedLines.sublist(2).join(' ');
          }
        }
        break;
      case 'direccion':
        final address = regionText
            .replaceAll(RegExp(r'DOMICILIO', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if ((merged['direccion'] ?? '').trim().length < address.length &&
            address.length >= 18) {
          merged['direccion'] = address;
        }
        break;
      case 'claveElectoral':
        final clave = extract(RegExp(r'([A-Z0-9]{16,20})'));
        if (clave != null && clave.length >= 16) {
          merged['claveElectoral'] = clave;
          merged['claveElector'] = clave;
        }
        break;
      case 'curp':
        final curp = extract(RegExp(r'([A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2})'));
        if (curp != null && curp.length >= 18) {
          merged['curp'] = curp;
        }
        break;
      case 'fechaNacimiento':
        final birthDate = extract(RegExp(r'(\d{2}/\d{2}/\d{4})'));
        if (birthDate != null) {
          merged['fechaNacimiento'] = birthDate;
        }
        break;
      case 'seccionElectoral':
        final section = extract(RegExp(r'([0-9]{3,4})'));
        if (section != null) {
          merged['seccionElectoral'] = section;
          merged['seccion'] = section;
        }
        break;
      case 'vigencia':
        final vigencia = extract(RegExp(r'([0-9]{4}\s*-\s*[0-9]{4})'));
        if (vigencia != null) {
          merged['vigencia'] = vigencia;
        }
        break;
      case 'sexo':
        final sexo = extract(RegExp(r'\b([HM])\b'));
        if (sexo != null) {
          merged['sexo'] = sexo;
        }
        break;
      case 'metaDerecha':
        final sexo = extract(RegExp(r'SEXO\s*([HM])')) ??
            extract(RegExp(r'\b([HM])\b'));
        final birthDate = extract(RegExp(r'(\d{2}/\d{2}/\d{4})'));
        final section = extract(RegExp(r'SECCI[OÓ]N\s*([0-9]{3,4})')) ??
            extract(RegExp(r'\b([0-9]{4})\b'));
        final vigencia = extract(RegExp(r'([0-9]{4}\s*-\s*[0-9]{4})'));
        if (sexo != null) {
          merged['sexo'] = sexo;
        }
        if (birthDate != null) {
          merged['fechaNacimiento'] = birthDate;
        }
        if (section != null) {
          merged['seccionElectoral'] = section;
          merged['seccion'] = section;
        }
        if (vigencia != null) {
          merged['vigencia'] = vigencia;
        }
        break;
    }

    for (final entry in regionRaw.entries) {
      final current = (merged[entry.key] ?? '').trim();
      final value = entry.value.trim();
      if (value.isEmpty) continue;
      if (current.isEmpty || value.length > current.length) {
        merged[entry.key] = value;
      }
    }
  }

  Future<List<String>> _prepareIosCapturedImageCandidates(String imagePath) async {
    if (!Platform.isIOS) {
      return <String>[imagePath];
    }

    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return <String>[imagePath];

      final oriented = img.bakeOrientation(decoded);
      final results = <String>[imagePath];
      final tempDir = await getTemporaryDirectory();
      final fullCardProfiles =
          <({double contrast, double brightness, double gamma, int width})>[
            (contrast: 1.10, brightness: 0.02, gamma: 0.96, width: 2400),
            (contrast: 1.22, brightness: 0.03, gamma: 0.92, width: 2600),
            (contrast: 1.34, brightness: 0.02, gamma: 0.90, width: 2800),
            (contrast: 1.42, brightness: 0.01, gamma: 0.88, width: 3000),
          ];
      final profiles =
          <({double widthFactor, double heightFactor, double verticalCenter})>[
        (
          widthFactor: 0.92,
          heightFactor: 0.58,
          verticalCenter: 0.54,
        ),
        (
          widthFactor: 0.82,
          heightFactor: 0.34,
          verticalCenter: 0.50,
        ),
        (
          widthFactor: _iosOcrCropWidthFactor,
          heightFactor: _iosOcrCropHeightFactor,
          verticalCenter: 0.52,
        ),
        (
          widthFactor: 0.44,
          heightFactor: 0.22,
          verticalCenter: 0.30,
        ),
        (
          widthFactor: 0.56,
          heightFactor: 0.24,
          verticalCenter: 0.48,
        ),
        (
          widthFactor: 0.60,
          heightFactor: 0.22,
          verticalCenter: 0.66,
        ),
        (
          widthFactor: 0.72,
          heightFactor: 0.27,
          verticalCenter: 0.53,
        ),
      ];

      for (int i = 0; i < fullCardProfiles.length; i++) {
        final profile = fullCardProfiles[i];
        final resized = oriented.width < profile.width
            ? img.copyResize(oriented, width: profile.width)
            : oriented.width > profile.width
                ? img.copyResize(oriented, width: profile.width)
                : oriented;
        final adjusted = img.adjustColor(
          resized,
          contrast: profile.contrast,
          brightness: profile.brightness,
          gamma: profile.gamma,
        );
        final sharpened = img.convolution(
          adjusted,
          filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
        );
        final fullGray = img.grayscale(img.Image.from(sharpened));
        final fullEnhanced = img.adjustColor(
          fullGray,
          contrast: math.min(profile.contrast + 0.22, 1.70),
          brightness: math.max(profile.brightness - 0.01, -0.02),
          gamma: math.max(profile.gamma - 0.03, 0.84),
        );
        final fullPath = p.join(
          tempDir.path,
          'ios_manual_full_${i}_${DateTime.now().microsecondsSinceEpoch}.jpg',
        );
        await File(fullPath).writeAsBytes(
          img.encodeJpg(fullEnhanced, quality: 98),
        );
        results.add(fullPath);
      }

      for (int i = 0; i < profiles.length; i++) {
        final profile = profiles[i];
        final cropWidth = (oriented.width * profile.widthFactor).round();
        final cropHeight = (oriented.height * profile.heightFactor).round();
        final left = ((oriented.width - cropWidth) / 2).round().clamp(
          0,
          oriented.width - 1,
        );
        final top = ((oriented.height * profile.verticalCenter) - cropHeight / 2)
            .round()
            .clamp(0, oriented.height - 1);
        final safeWidth = math.min(cropWidth, oriented.width - left);
        final safeHeight = math.min(cropHeight, oriented.height - top);

        if (safeWidth < 1100 || safeHeight < 600) {
          continue;
        }

        final cropped = img.copyCrop(
          oriented,
          x: left,
          y: top,
          width: safeWidth,
          height: safeHeight,
        );

        final normalized = cropped.width < 2600
            ? img.copyResize(cropped, width: 2600)
            : cropped;

        final enhancedBase = img.adjustColor(
          normalized,
          contrast: 1.24,
          brightness: 0.02,
          gamma: 0.93,
        );

        final sharpened = img.convolution(
          enhancedBase,
          filter: const [0, -1, 0, -1, 5, -1, 0, -1, 0],
        );

        final enhanced = img.adjustColor(
          img.grayscale(img.Image.from(sharpened)),
          contrast: 1.26,
          brightness: 0.01,
          gamma: 0.92,
        );

        final croppedPath = p.join(
          tempDir.path,
          'ios_manual_ocr_${i}_${DateTime.now().microsecondsSinceEpoch}.jpg',
        );

        await File(croppedPath).writeAsBytes(
          img.encodeJpg(enhanced, quality: 98),
        );

        results.add(croppedPath);
      }

      return results;
    } catch (_) {
      return <String>[imagePath];
    }
  }

  Widget _buildAndroidBody() {
    return Positioned.fill(
      child: Container(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Escaneo de INE',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Usa el escaner inteligente para capturar la credencial y continuar con la lectura OCR.',
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: Color(0xFF4B5563),
                    ),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _processing ? null : _scanWithDocumentScanner,
                      icon: const Icon(Icons.document_scanner_outlined),
                      label: Text(
                        _processing ? 'Procesando...' : 'Abrir escaner',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIosBody() {
    if (!_iosManualFallbackMode) {
      return Positioned.fill(
        child: Container(
          color: const Color(0xFFF4F4F5),
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Captura de INE en iPhone',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _iosHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.4,
                        color: Color(0xFF4B5563),
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _processing
                            ? null
                            : () => _activateIosManualFallback(),
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: const Text('Abrir camara'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final controller = _iosCameraController;

    if (!_iosCameraReady || controller == null || !controller.value.isInitialized) {
      return Positioned.fill(
        child: Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(controller),
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.18),
            ),
          ),
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.84,
              height: MediaQuery.of(context).size.height * 0.33,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white, width: 3),
              ),
            ),
          ),
          Positioned(
            top: 32,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Escaneo de INE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _iosHint,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Captura manual optimizada',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _processing || _iosCaptureInProgress
                      ? null
                      : _takeSingleAutoPicture,
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Tomar ahora'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _processing || _iosCaptureInProgress
                      ? null
                      : () async {
                          final controller = _iosCameraController;
                          if (controller == null ||
                              !controller.value.isInitialized) {
                            return;
                          }
                          await _configureIosCamera(controller);
                          if (!mounted) return;
                          setState(() {
                            _iosHint =
                                'Camara lista. Centra la INE completa y toca "Tomar ahora" cuando el texto se vea claro.';
                          });
                        },
                  icon: const Icon(Icons.center_focus_strong_outlined),
                  label: const Text('Reenfocar camara'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Platform.isIOS ? _buildIosBody() : _buildAndroidBody(),
            if (_processing)
              Positioned.fill(
                child: Container(
                  color: Colors.black87,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.white),
                        const SizedBox(height: 16),
                        Text(
                          _processingMessage,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Esto puede tardar unos segundos',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (!_processing)
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  color: Colors.white,
                  icon: const Icon(Icons.close, size: 30),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ImageQualityCheck {
  final String? blockingMessage;
  final String? warningMessage;

  const _ImageQualityCheck({
    this.blockingMessage,
    this.warningMessage,
  });
}

class _IosOcrResult {
  final Map<String, String> rawResult;
  final OcrValidationResult validation;

  const _IosOcrResult({
    required this.rawResult,
    required this.validation,
  });
}
