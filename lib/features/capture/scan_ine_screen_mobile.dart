import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:doc_scan_flutter/doc_scan.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/routes.dart';
import '../../services/ios_native_ine_scanner.dart';
import '../../services/ocr_service.dart';
import '../../services/ocr_validation_service.dart';
import '../../services/web_ocr_parser.dart';
import 'package:flutter/services.dart';

class ScanIneScreen extends StatefulWidget {
  const ScanIneScreen({super.key});

  @override
  State<ScanIneScreen> createState() => _ScanIneScreenState();
}

class _ScanIneScreenState extends State<ScanIneScreen> {
  static const int _qualityCheckMaxWidth = 960;
  static const Duration _ocrTimeout = Duration(seconds: 28);
  static const Duration _iosFrameAnalysisGap = Duration(milliseconds: 420);
  static const Duration _iosPreCaptureFocusWait = Duration(milliseconds: 850);
  static const int _iosRequiredStableFrames = 3;
  static const double _iosMotionThreshold = 10.5;
  static const double _iosPreviewEdgeThreshold = 18;
  static const double _iosPreviewContrastThreshold = 18;
  static const double _iosBlockingBlurThreshold = 7.2;
  static const double _iosWarningBlurThreshold = 10.0;

  bool _processing = false;
  bool _scannerOpened = false;
  bool _openingNativeScanner = false;
  String _processingMessage = 'Procesando datos...';

  CameraController? _iosCameraController;
  bool _iosManualFallbackMode = false;
  bool _iosCameraReady = false;
  bool _iosCameraInitializing = false;
  bool _iosCaptureInProgress = false;
  bool _iosStreaming = false;
  String _iosHint = 'Acomoda la INE dentro del recuadro. La captura sera automatica.';
  DateTime? _iosLastAnalysisAt;
  List<int>? _iosPreviousLumaSample;
  int _iosStableFrames = 0;

  @override
  void initState() {
    super.initState();

    if (Platform.isIOS) {
      _processingMessage = 'Preparando camara...';
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scannerOpened) return;
      _scannerOpened = true;
      if (Platform.isIOS) {
        Future<void>.delayed(const Duration(milliseconds: 350), () {
          if (!mounted) return;
          _scanWithDocumentScanner();
        });
      } else {
        _scanWithDocumentScanner();
      }
    });
  }

  @override
  void dispose() {
    _disposeIosCamera();
    super.dispose();
  }

  Future<void> _initializeIosCamera() async {
    if (!Platform.isIOS || _iosCameraInitializing) return;

    _iosCameraInitializing = true;

    try {
      final cameras = await availableCameras();
      final rearCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        rearCamera,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup:
            Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );

      await controller.initialize();
      await controller.setFlashMode(FlashMode.off);
      await _configureIosCamera(controller);

      _iosCameraController = controller;
      _iosCameraReady = true;

      if (mounted) {
        setState(() {});
      }

      await Future<void>.delayed(const Duration(milliseconds: 180));
      await _startIosImageStream();
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
        _iosManualFallbackMode = true;
        _processing = false;
        _processingMessage = 'Procesando datos...';
        _iosHint =
            'Acomoda la INE dentro del recuadro. La captura sera automatica.';
      });
    }

    if (snackMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(snackMessage)),
      );
    }

    await _initializeIosCamera();
  }

  Future<void> _disposeIosCamera() async {
    final controller = _iosCameraController;
    _iosCameraController = null;
    _iosStreaming = false;
    _iosCameraReady = false;

    if (controller == null) return;

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}

    await controller.dispose();
  }

  Future<void> _startIosImageStream() async {
    final controller = _iosCameraController;
    if (!Platform.isIOS || controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_iosStreaming || _iosCaptureInProgress || _processing) return;

    _iosPreviousLumaSample = null;
    _iosLastAnalysisAt = null;
    _iosStableFrames = 0;

    await controller.startImageStream((CameraImage image) async {
      if (!_iosStreaming || _iosCaptureInProgress || _processing) return;

      final now = DateTime.now();
      if (_iosLastAnalysisAt != null &&
          now.difference(_iosLastAnalysisAt!) < _iosFrameAnalysisGap) {
        return;
      }
      _iosLastAnalysisAt = now;

      final signal = _analyzeIosFrame(image);
      final previous = _iosPreviousLumaSample;
      final motion = previous == null
          ? double.infinity
          : _calculateMotion(previous, signal.sample);

      _iosPreviousLumaSample = signal.sample;

      final hasEnoughDetail =
          signal.edgeScore > _iosPreviewEdgeThreshold &&
          signal.contrast > _iosPreviewContrastThreshold;
      final brightnessOk = signal.brightness > 45 && signal.brightness < 228;
      final isStable = motion < _iosMotionThreshold;

      if (hasEnoughDetail && brightnessOk && isStable) {
        _iosStableFrames += 1;
      } else {
        _iosStableFrames = 0;
      }

      if (!mounted) return;

      if (_iosStableFrames >= _iosRequiredStableFrames) {
        setState(() {
          _iosHint = 'Documento enfocado y estable. Tomando foto...';
        });
        await _takeSingleAutoPicture();
        return;
      }

      final nextHint = hasEnoughDetail
          ? 'Manten la INE quieta dentro del recuadro...'
          : 'Ajusta distancia y enfoque. La INE debe verse nitida dentro del recuadro.';

      if (_iosHint != nextHint) {
        setState(() {
          _iosHint = nextHint;
        });
      }
    });

    _iosStreaming = true;
  }

  _IosFrameSignal _analyzeIosFrame(CameraImage image) {
    final plane = image.planes.first;
    final bytes = plane.bytes;
    final bytesPerRow = plane.bytesPerRow;
    final width = image.width;
    final height = image.height;

    final left = (width * 0.18).floor();
    final right = (width * 0.82).floor();
    final top = (height * 0.26).floor();
    final bottom = (height * 0.74).floor();

    final sample = <int>[];
    double brightnessSum = 0;
    double edgeSum = 0;
    int count = 0;

    for (int y = top; y < bottom - 2; y += 14) {
      for (int x = left; x < right - 2; x += 14) {
        final index = y * bytesPerRow + x;
        final center = bytes[index];
        final rightPixel = bytes[index + 1];
        final bottomPixel = bytes[index + bytesPerRow];

        brightnessSum += center;
        edgeSum +=
            (center - rightPixel).abs() + (center - bottomPixel).abs();
        sample.add(center);
        count++;
      }
    }

    if (count == 0) {
      return const _IosFrameSignal(
        brightness: 0,
        edgeScore: 0,
        contrast: 0,
        sample: <int>[],
      );
    }

    final brightness = brightnessSum / count;
    double varianceSum = 0;
    for (final value in sample) {
      varianceSum += math.pow(value - brightness, 2).toDouble();
    }

    final contrast = math.sqrt(varianceSum / count);
    return _IosFrameSignal(
      brightness: brightness,
      edgeScore: edgeSum / count,
      contrast: contrast,
      sample: sample,
    );
  }

  double _calculateMotion(List<int> previous, List<int> current) {
    final length = math.min(previous.length, current.length);
    if (length == 0) return double.infinity;

    double diff = 0;
    for (int i = 0; i < length; i++) {
      diff += (previous[i] - current[i]).abs();
    }
    return diff / length;
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
  }

  Future<void> _prepareIosFocusForCapture(CameraController controller) async {
    await _configureIosCamera(controller);

    try {
      await controller.setZoomLevel(1.0);
    } catch (_) {}

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
      if (controller.value.isStreamingImages) {
        _iosStreaming = false;
        await controller.stopImageStream();
      }

      await _prepareIosFocusForCapture(controller);

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
              'No se pudo leer bien. Reacomoda la INE y mantela quieta para reintentar.';
        });
        _iosCaptureInProgress = false;
        await _startIosImageStream();
        return;
      }
    } catch (_) {
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

      if (sampleImage.width < 700 || sampleImage.height < 420) {
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
          warningMessage: 'La imagen se ve oscura. La lectura podria bajar.',
        );
      }

      if (avgBrightness > 248) {
        return const _ImageQualityCheck(
          warningMessage:
              'La imagen tiene mucho brillo o reflejo. La lectura podria bajar.',
        );
      }

      if (avgEdge < _iosBlockingBlurThreshold) {
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
      _openingNativeScanner = true;

      try {
        if (mounted) {
          setState(() {
            _processing = true;
            _processingMessage = 'Abriendo escaner inteligente...';
          });
        }

        final nativeScan = await IosNativeIneScanner().scanIne();
        if (nativeScan == null) {
          if (mounted) {
            setState(() => _processing = false);
          }
          return;
        }

        final nativeRaw = await WebOcrParser().parse(nativeScan.rawText);
        nativeRaw['rawText'] = nativeScan.rawText;
        nativeRaw['processingMode'] = nativeScan.source;

        final success = await _processImagePath(
          nativeScan.imagePath,
          preferredRawResult: nativeRaw,
        );

        if (!success && mounted) {
          await _activateIosManualFallback(
            'La lectura nativa no quedo suficientemente clara. Cambiamos a captura automatica.',
          );
        }
      } on PlatformException catch (_) {
        await _activateIosManualFallback(
          'El escaner nativo no estuvo disponible. Usaremos la camara automatica.',
        );
      } catch (_) {
        await _activateIosManualFallback(
          'El escaner nativo fallo. Usaremos la camara automatica.',
        );
      } finally {
        _openingNativeScanner = false;
      }
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
      if (Platform.isIOS) {
        await _activateIosManualFallback(
          'No se pudo abrir el escaner inteligente. Cambiamos a captura automatica.',
        );
        return;
      }
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo escanear el documento. Intenta de nuevo.'),
        ),
      );
    } catch (_) {
      if (Platform.isIOS) {
        await _activateIosManualFallback(
          'El escaner inteligente no estuvo disponible. Usaremos la camara automatica.',
        );
        return;
      }
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
    final isNativeIosScan =
        Platform.isIOS &&
        (preferredRawResult?['processingMode'] ?? '').contains(
          'ios_visionkit_native',
        );

    if (!mounted) return false;

    setState(() {
      _processing = true;
      _processingMessage = 'Validando calidad de imagen...';
    });

    final qualityCheck = await _validateImageQuality(imagePath);
    if (qualityCheck.blockingMessage != null) {
      if (isNativeIosScan) {
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
        _IosOcrResult? bestResult;

        if (preferredRawResult != null) {
          final preferredValidation = validator.validate(preferredRawResult);
          bestResult = _IosOcrResult(
            rawResult: preferredRawResult,
            validation: preferredValidation,
          );
        }

        final refinedResult = await _scanIneWithIosRefinement(
          ocr,
          imagePath,
        ).timeout(_ocrTimeout);

        if (bestResult == null ||
            _iosValidationScore(refinedResult.validation) >
                _iosValidationScore(bestResult.validation)) {
          bestResult = refinedResult;
        }

        rawResult = bestResult.rawResult;
        validation = bestResult.validation;
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
      if (isNativeIosScan && preferredRawResult != null && mounted) {
        final fallbackValidation = validator.validate(preferredRawResult);
        final data = Map<String, dynamic>.from(fallbackValidation.normalizedData);

        data['processingMode'] =
            preferredRawResult['processingMode'] ?? 'ios_visionkit_native';
        data['globalConfidence'] = fallbackValidation.globalConfidence;

        Navigator.pushReplacementNamed(
          context,
          AppRoutes.ocrReview,
          arguments: {
            ...data,
            'warnings': fallbackValidation.warnings,
            'confidence': fallbackValidation.confidence,
            'imagePath': imagePath,
            'rawText': preferredRawResult['rawText'] ?? '',
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
  ) async {
    final primaryRaw = await ocr.scanIne(imagePath);
    final primaryValidation = OcrValidationService().validate(primaryRaw);

    if (!_shouldRetryIosOcr(primaryValidation)) {
      return _IosOcrResult(
        rawResult: primaryRaw,
        validation: primaryValidation,
      );
    }

    if (mounted) {
      setState(() {
        _processingMessage = 'Refinando lectura para iPhone...';
      });
    }

    final enhancedPath = await _createIosEnhancedImage(imagePath);
    if (enhancedPath == null) {
      return _IosOcrResult(
        rawResult: primaryRaw,
        validation: primaryValidation,
      );
    }

    try {
      final refinedRaw = await ocr.scanIne(enhancedPath);
      final refinedValidation = OcrValidationService().validate(refinedRaw);

      if (_iosValidationScore(refinedValidation) >
          _iosValidationScore(primaryValidation)) {
        return _IosOcrResult(
          rawResult: refinedRaw,
          validation: refinedValidation,
        );
      }
    } catch (_) {
      // Si el refinado falla, conservamos el primer resultado.
    }

    return _IosOcrResult(
      rawResult: primaryRaw,
      validation: primaryValidation,
    );
  }

  bool _shouldRetryIosOcr(OcrValidationResult validation) {
    final normalized = validation.normalizedData;
    final clave = (normalized['claveElectoral'] ?? '').trim();
    final curp = (normalized['curp'] ?? '').trim();
    final direccion = (normalized['direccion'] ?? '').trim();
    final nombre = (normalized['nombre'] ?? '').trim();

    if (validation.globalConfidence < 0.84) return true;
    if (clave.isEmpty || curp.isEmpty) return true;
    if (direccion.length < 10) return true;
    if (nombre.length < 3) return true;
    if ((validation.confidence['claveElectoral'] ?? 0) < 0.90) return true;
    if ((validation.confidence['curp'] ?? 0) < 0.90) return true;
    return false;
  }

  double _iosValidationScore(OcrValidationResult validation) {
    return validation.globalConfidence * 10 +
        (validation.confidence['claveElectoral'] ?? 0.0) * 5 +
        (validation.confidence['curp'] ?? 0.0) * 5 +
        (validation.confidence['direccion'] ?? 0.0) * 3 +
        (validation.confidence['nombre'] ?? 0.0) * 2 +
        (validation.confidence['apellidoPaterno'] ?? 0.0) * 2 +
        (validation.confidence['fechaNacimiento'] ?? 0.0) * 2 +
        (validation.confidence['vigencia'] ?? 0.0) * 2 +
        (validation.confidence['seccionElectoral'] ?? 0.0) * 1.5;
  }

  Future<String?> _createIosEnhancedImage(String imagePath) async {
    try {
      final bytes = await File(imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;

      var working = img.bakeOrientation(decoded);
      if (working.width > 2200) {
        working = img.copyResize(working, width: 2200);
      }

      final gray = img.grayscale(img.Image.from(working));
      final enhanced = img.adjustColor(
        gray,
        contrast: 1.35,
        brightness: 0.04,
        gamma: 0.92,
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
                    const CircularProgressIndicator(),
                    const SizedBox(height: 18),
                    const Text(
                      'Preparando escaneo inteligente en iPhone...',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Si el escaner nativo no abre, cambiaremos automaticamente a la captura con camara.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
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
                        label: const Text('Usar captura automatica ahora'),
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
                  'Captura automatica activada',
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
                      : _scanWithDocumentScanner,
                  icon: const Icon(Icons.document_scanner_outlined),
                  label: const Text('Usar escaner inteligente'),
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

class _IosFrameSignal {
  final double brightness;
  final double edgeScore;
  final double contrast;
  final List<int> sample;

  const _IosFrameSignal({
    required this.brightness,
    required this.edgeScore,
    required this.contrast,
    required this.sample,
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
