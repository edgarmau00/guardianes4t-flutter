import 'dart:async';
import 'dart:convert';
import 'dart:js_util' as js_util;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../app/routes.dart';
import '../../services/ocr_validation_service.dart';
import '../../services/web_document_detector.dart';
import '../../services/web_ocr_parser.dart';

class ScanIneScreen extends StatefulWidget {
  const ScanIneScreen({super.key});

  @override
  State<ScanIneScreen> createState() => _ScanIneScreenState();
}

class _ScanIneScreenState extends State<ScanIneScreen> {
  static const Duration _ocrTimeout = Duration(seconds: 45);
  static const Duration _analysisGap = Duration(milliseconds: 240);
  static const int _requiredStableFrames = 2;
  static const String _visionScriptAsset = 'guardianes4t_vision.js';
  static const String _tesseractScriptAsset = 'ocr/tesseract.min.js';
  static const String _tesseractWorkerAsset = 'ocr/worker.min.js';
  static const String _tesseractLangAsset = 'ocr';
  static const String _tesseractCoreAsset = 'ocr/tesseract-core-simd.wasm.js';

  final ImagePicker _imagePicker = ImagePicker();
  final WebDocumentDetector _documentDetector = WebDocumentDetector();
  final String _viewId =
      'guardianes4t-web-camera-${DateTime.now().microsecondsSinceEpoch}';

  html.VideoElement? _videoElement;
  html.CanvasElement? _analysisCanvas;
  html.MediaStream? _mediaStream;
  Timer? _analysisTimer;
  DocumentRect? _lastDetectedRect;
  Future<void>? _tesseractLoader;
  Future<void>? _visionLoader;

  bool _cameraReady = false;
  bool _processing = false;
  bool _initializingCamera = true;
  int _stableFrames = 0;
  String _message =
      'Coloca la INE dentro del recuadro. Cuando la detectemos estable, la capturamos automaticamente.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeCamera();
    });
  }

  @override
  void dispose() {
    _analysisTimer?.cancel();
    _stopCamera();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    try {
      final video = html.VideoElement()
        ..autoplay = true
        ..muted = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.objectFit = 'cover'
        ..style.border = '0'
        ..style.backgroundColor = '#111827';

      final mediaDevices = html.window.navigator.mediaDevices;
      if (mediaDevices == null) {
        throw StateError('La camara no esta disponible en este navegador.');
      }

      final constraints = <String, dynamic>{
        'audio': false,
        'video': <String, dynamic>{
          'facingMode': <String, dynamic>{'ideal': 'environment'},
          'aspectRatio': <String, dynamic>{'ideal': 4 / 3},
          'width': <String, dynamic>{'ideal': 2560},
          'height': <String, dynamic>{'ideal': 1920},
        },
      };

      final stream = await mediaDevices.getUserMedia(constraints);
      await _applyPreferredTrackConstraints(stream);
      video.srcObject = stream;
      await video.play();

      ui_web.platformViewRegistry.registerViewFactory(_viewId, (int _) => video);

      _videoElement = video;
      _mediaStream = stream;
      _analysisCanvas = html.CanvasElement(width: 960, height: 600);

      await _waitForVideoFrame(video);
      await _ensureVisionLoaded();
      _startAnalysisLoop();

      if (!mounted) return;
      setState(() {
        _cameraReady = true;
        _initializingCamera = false;
        _message =
            'Manten la INE centrada y quieta. La captura se hara sola cuando la lectura sea estable.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _initializingCamera = false;
        _message =
            'No se pudo abrir la camara en Safari. Puedes intentar de nuevo o elegir una foto de la galeria.';
      });
    }
  }

  Future<void> _applyPreferredTrackConstraints(html.MediaStream stream) async {
    try {
      final tracks = stream.getVideoTracks();
      if (tracks.isEmpty) return;

      final track = tracks.first;
      final advanced = <Map<String, dynamic>>[
        {'focusMode': 'continuous'},
        {'exposureMode': 'continuous'},
        {'whiteBalanceMode': 'continuous'},
      ];

      final capabilities = js_util.callMethod<Object?>(track, 'getCapabilities', []);
      if (capabilities != null) {
        final zoom = js_util.getProperty<Object?>(capabilities, 'zoom');
        if (zoom != null) {
          final min = (js_util.getProperty<num>(zoom, 'min')).toDouble();
          final max = (js_util.getProperty<num>(zoom, 'max')).toDouble();
          final preferred = (min + ((max - min) * 0.18)).clamp(min, max);
          advanced.add({'zoom': preferred});
        }

        final torch = js_util.getProperty<Object?>(capabilities, 'torch');
        if (torch == true) {
          advanced.add({'torch': false});
        }
      }

      final promise = js_util.callMethod<Object?>(
        track,
        'applyConstraints',
        [
          {
            'advanced': advanced,
          },
        ],
      );

      if (promise != null) {
        await js_util.promiseToFuture<Object?>(promise);
      }
    } catch (_) {}
  }

  Future<void> _waitForVideoFrame(html.VideoElement video) async {
    if (video.videoWidth > 0 && video.videoHeight > 0) {
      return;
    }

    final completer = Completer<void>();
    late html.EventListener listener;
    listener = (_) {
      if (!completer.isCompleted &&
          video.videoWidth > 0 &&
          video.videoHeight > 0) {
        video.removeEventListener('loadedmetadata', listener);
        completer.complete();
      }
    };
    video.addEventListener('loadedmetadata', listener);
    await completer.future.timeout(const Duration(seconds: 10));
  }

  void _startAnalysisLoop() {
    _analysisTimer?.cancel();
    _analysisTimer = Timer.periodic(_analysisGap, (_) async {
      if (_processing || !_cameraReady || _videoElement == null) return;

      final analysis = _analyzeCurrentFrame();

      if (!mounted) return;
      setState(() {
        _message = analysis.message;
        _lastDetectedRect = analysis.rect;
      });

      if (analysis.readyForAutoCapture) {
        _stableFrames += 1;
      } else {
        _stableFrames = 0;
      }

      if (_stableFrames >= _requiredStableFrames) {
        _stableFrames = 0;
        await _captureFromLiveCamera();
      }
    });
  }

  DocumentFrameAnalysis _analyzeCurrentFrame() {
    final video = _videoElement;
    final canvas = _analysisCanvas;
    if (video == null || canvas == null) {
      return const DocumentFrameAnalysis(
        message: 'Preparando camara...',
        readyForAutoCapture: false,
      );
    }
    if (video.videoWidth <= 0 || video.videoHeight <= 0) {
      return const DocumentFrameAnalysis(
        message: 'Esperando video de la camara...',
        readyForAutoCapture: false,
      );
    }

    return _documentDetector.analyzeFrame(
      video: video,
      canvas: canvas,
      previousRect: _lastDetectedRect,
    );
  }

  Future<void> _captureFromLiveCamera() async {
    final video = _videoElement;
    if (video == null || _processing) return;
    if (video.videoWidth <= 0 || video.videoHeight <= 0) return;

    final bytes = await _captureBestWebDocument(video);
    await _processImageBytes(bytes, sourceLabel: 'camara');
  }

  Future<Uint8List> _captureBestWebDocument(html.VideoElement video) async {
    final sourceBytes =
        await _captureStillPhotoBytes() ?? _capturePreviewFrameBytes(video);
    final sourceCanvas = await _bytesToCanvas(sourceBytes);

    try {
      await _ensureVisionLoaded();
      final vision = js_util.getProperty<Object?>(html.window, 'Guardianes4TVision');
      if (vision != null) {
        final detectionPromise = js_util.callMethod<Object?>(
          vision,
          'detectDocument',
          [sourceCanvas],
        );
        final detection = detectionPromise == null
            ? null
            : await js_util.promiseToFuture<Object?>(detectionPromise);

        final points = detection == null
            ? null
            : js_util.getProperty<Object?>(detection, 'points');

        if (points != null) {
          final perspectivePromise = js_util.callMethod<Object?>(
            vision,
            'cropPerspective',
            [sourceCanvas, points],
          );
          final perspectiveUrl = perspectivePromise == null
              ? null
              : await js_util.promiseToFuture<Object?>(perspectivePromise);

          if (perspectiveUrl is String && perspectiveUrl.isNotEmpty) {
            return UriData.parse(perspectiveUrl).contentAsBytes();
          }
        }
      }
    } catch (_) {}

    return _documentDetector.captureDocumentFromBytes(
      imageBytes: sourceBytes,
      detectedRect: _lastDetectedRect,
      sourceWidth: sourceCanvas.width?.toDouble(),
      sourceHeight: sourceCanvas.height?.toDouble(),
    );
  }

  Future<Uint8List?> _captureStillPhotoBytes() async {
    final stream = _mediaStream;
    if (stream == null) return null;

    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) return null;

    try {
      final imageCaptureCtor =
          js_util.getProperty<Object?>(html.window, 'ImageCapture');
      if (imageCaptureCtor == null) {
        return null;
      }

      final imageCapture = js_util.callConstructor<Object?>(
        imageCaptureCtor,
        [tracks.first],
      );
      if (imageCapture == null) {
        return null;
      }

      final photoPromise = js_util.callMethod<Object?>(
        imageCapture,
        'takePhoto',
        const [],
      );
      if (photoPromise == null) {
        return null;
      }
      final photo = await js_util.promiseToFuture<Object?>(photoPromise);
      if (photo is! html.Blob) {
        return null;
      }

      return _blobToBytes(photo);
    } catch (_) {
      return null;
    }
  }

  Uint8List _capturePreviewFrameBytes(html.VideoElement video) {
    final canvas = html.CanvasElement(
      width: video.videoWidth,
      height: video.videoHeight,
    );
    canvas.context2D.drawImageScaled(
      video,
      0,
      0,
      canvas.width!,
      canvas.height!,
    );
    final dataUrl = canvas.toDataUrl('image/png');
    return UriData.parse(dataUrl).contentAsBytes();
  }

  Future<Uint8List> _blobToBytes(html.Blob blob) {
    final completer = Completer<Uint8List>();
    final reader = html.FileReader();

    late html.EventListener onLoadEnd;
    late html.EventListener onError;

    onLoadEnd = (_) {
      reader.removeEventListener('loadend', onLoadEnd);
      reader.removeEventListener('error', onError);

      final result = reader.result;
      if (result is ByteBuffer) {
        completer.complete(Uint8List.view(result));
        return;
      }

      completer.completeError(
        StateError('No se pudo convertir la foto de la camara.'),
      );
    };

    onError = (_) {
      reader.removeEventListener('loadend', onLoadEnd);
      reader.removeEventListener('error', onError);
      completer.completeError(
        StateError('No se pudo leer la foto capturada.'),
      );
    };

    reader.addEventListener('loadend', onLoadEnd);
    reader.addEventListener('error', onError);
    reader.readAsArrayBuffer(blob);

    return completer.future;
  }

  Future<html.CanvasElement> _bytesToCanvas(Uint8List bytes) async {
    final image = await _bytesToImage(bytes);
    final canvas = html.CanvasElement(
      width: image.width,
      height: image.height,
    );
    canvas.context2D.drawImage(image, 0, 0);
    return canvas;
  }

  Future<html.ImageElement> _bytesToImage(Uint8List bytes) {
    final completer = Completer<html.ImageElement>();
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final image = html.ImageElement();

    late html.EventListener onLoad;
    late html.EventListener onError;

    onLoad = (_) {
      image.removeEventListener('load', onLoad);
      image.removeEventListener('error', onError);
      html.Url.revokeObjectUrl(url);
      completer.complete(image);
    };

    onError = (_) {
      image.removeEventListener('load', onLoad);
      image.removeEventListener('error', onError);
      html.Url.revokeObjectUrl(url);
      completer.completeError(
        StateError('No se pudo preparar la foto para OCR web.'),
      );
    };

    image.addEventListener('load', onLoad);
    image.addEventListener('error', onError);
    image.src = url;

    return completer.future;
  }

  Future<void> _pickFromGallery() async {
    if (_processing) return;

    try {
      setState(() {
        _processing = true;
        _message = 'Abriendo galeria...';
      });

      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 92,
        maxWidth: 1800,
      );

      if (picked == null) {
        if (!mounted) return;
        setState(() {
          _processing = false;
          _message =
              'Manten la INE centrada y quieta. La captura se hara sola cuando la lectura sea estable.';
        });
        return;
      }

      await _processImageBytes(await picked.readAsBytes(), sourceLabel: 'galeria');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _message =
            'No se pudo abrir la galeria. Intenta otra vez o usa la camara.';
      });
    }
  }

  Future<void> _processImageBytes(
    Uint8List bytes, {
    required String sourceLabel,
  }) async {
    Uint8List? previewBytes;
    try {
      if (!mounted) return;
      setState(() {
        _processing = true;
        _message = sourceLabel == 'camara'
            ? 'Procesando captura automatica...'
            : 'Preparando imagen seleccionada...';
      });

      previewBytes = _normalizeForPreview(bytes);

      if (!mounted) return;
      setState(() {
        _message = 'Leyendo texto con OCR web...';
      });

      final bestResult =
          await _runBestWebOcrPass(previewBytes).timeout(_ocrTimeout);
      final rawText = bestResult.rawText;
      final parsed = bestResult.parsed;
      final validation = bestResult.validation;
      final normalized = Map<String, dynamic>.from(validation.normalizedData);

      if (!mounted) return;

      Navigator.pushReplacementNamed(
        context,
        AppRoutes.ocrReview,
        arguments: {
          ...normalized,
          'warnings': validation.warnings,
          'confidence': validation.confidence,
          'rawText': rawText,
          'imagePath': '',
          'processingMode': parsed['processingMode'] ?? 'web_tesseract',
          'globalConfidence': validation.globalConfidence,
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _message =
            'No se pudo leer la imagen. Intenta otra vez con mejor luz y un encuadre mas cerrado.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo completar la lectura OCR en web. Intenta nuevamente.',
          ),
        ),
      );
    } finally {
      _wipeBytes(bytes);
      if (previewBytes != null && !identical(previewBytes, bytes)) {
        _wipeBytes(previewBytes!);
      }
    }
  }

  Uint8List _normalizeForPreview(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    var normalized = decoded;
    if (decoded.height > decoded.width) {
      normalized = img.copyRotate(decoded, angle: 90);
    }

    if (normalized.width > 2400) {
      normalized = img.copyResize(normalized, width: 2400);
    } else if (normalized.width < 1800) {
      normalized = img.copyResize(normalized, width: 1800);
    }

    normalized = img.adjustColor(
      normalized,
      contrast: 1.12,
      saturation: 0.94,
      brightness: 1.01,
      gamma: 0.98,
    );

    return Uint8List.fromList(img.encodePng(normalized, level: 1));
  }

  Future<_BestWebOcrResult> _runBestWebOcrPass(Uint8List bytes) async {
    final variants = _buildOcrVariants(bytes);
    final results = <_WebOcrVariantResult>[];

    for (final variant in variants) {
      try {
        final rawText = await _runWebOcr(variant.bytes);
        final parsed = await WebOcrParser().parse(rawText);
        final validation = OcrValidationService().validate(parsed);
        results.add(
          _WebOcrVariantResult(
            label: variant.label,
            rawText: rawText,
            parsed: parsed,
            validation: validation,
          ),
        );
      } finally {
        if (!identical(variant.bytes, bytes)) {
          _wipeBytes(variant.bytes);
        }
      }
    }

    if (results.isEmpty) {
      throw StateError('No se pudo completar ninguna pasada OCR en web.');
    }

    results.sort(
      (a, b) =>
          b.validation.globalConfidence.compareTo(a.validation.globalConfidence),
    );

    final merged = _mergeVariantResults(results);
    final zoneParsed = await _runZoneBasedParse(bytes);
    final mergedWithZones = _mergePreferredFields(
      merged,
      zoneParsed,
      preferredKeys: const [
        'nombre',
        'apellidoPaterno',
        'apellidoMaterno',
        'direccion',
        'codigoPostal',
        'municipio',
        'estado',
        'claveElectoral',
        'claveElector',
        'curp',
        'fechaNacimiento',
        'seccionElectoral',
        'seccion',
        'vigencia',
        'sexo',
      ],
    );
    final mergedValidation = OcrValidationService().validate(mergedWithZones);

    return _BestWebOcrResult(
      rawText: results.map((e) => '[${e.label}]\n${e.rawText}').join('\n\n'),
      parsed: mergedWithZones,
      validation: mergedValidation,
    );
  }

  Future<Map<String, String>> _runZoneBasedParse(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return const <String, String>{};

    var base = decoded;
    if (base.width < 2200) {
      base = img.copyResize(base, width: 2200);
    } else if (base.width > 2600) {
      base = img.copyResize(base, width: 2600);
    }

    final zones = <String, img.Image>{
      'name': _cropRelative(base, x: 0.28, y: 0.16, w: 0.37, h: 0.22),
      'sexo': _cropRelative(base, x: 0.81, y: 0.16, w: 0.13, h: 0.10),
      'domicilio': _cropRelative(base, x: 0.28, y: 0.36, w: 0.48, h: 0.22),
      'clave': _cropRelative(base, x: 0.28, y: 0.55, w: 0.56, h: 0.08),
      'curp': _cropRelative(base, x: 0.28, y: 0.63, w: 0.46, h: 0.08),
      'fechaNacimiento': _cropRelative(base, x: 0.28, y: 0.73, w: 0.20, h: 0.09),
      'seccion': _cropRelative(base, x: 0.55, y: 0.73, w: 0.12, h: 0.09),
      'vigencia': _cropRelative(base, x: 0.68, y: 0.72, w: 0.19, h: 0.11),
    };

    final zoneTexts = <String, String>{};
    for (final entry in zones.entries) {
      final candidates = <String>[];
      for (final variant in _buildZoneVariants(entry.value)) {
        try {
          final raw = await _runWebOcr(variant);
          if (raw.trim().isNotEmpty) {
            candidates.add(raw);
          }
        } finally {
          _wipeBytes(variant);
        }
      }

      zoneTexts[entry.key] = _pickBestZoneText(entry.key, candidates);
    }

    final syntheticText = _buildSyntheticIneText(zoneTexts);
    if (syntheticText.trim().isEmpty) {
      return const <String, String>{};
    }

    return WebOcrParser().parse(syntheticText);
  }

  List<_WebOcrImageVariant> _buildOcrVariants(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return [_WebOcrImageVariant(label: 'base', bytes: bytes)];
    }

    img.Image prepareBase(img.Image source) {
      var out = source;
      if (out.width < 1800) {
        out = img.copyResize(out, width: 1800);
      } else if (out.width > 2800) {
        out = img.copyResize(out, width: 2800);
      }
      return out;
    }

    Uint8List encode(img.Image image) {
      return Uint8List.fromList(img.encodePng(image, level: 1));
    }

    final base = prepareBase(decoded);

    final contrast = img.adjustColor(
      base,
      contrast: 1.24,
      saturation: 0.92,
      brightness: 1.02,
      gamma: 0.98,
    );

    final sharpened = img.adjustColor(
      _sharpenForOcr(base),
      contrast: 1.34,
      saturation: 0.84,
      brightness: 1.01,
      gamma: 0.96,
    );

    final grayscale = img.grayscale(base);
    final grayscaleContrast = img.adjustColor(
      grayscale,
      contrast: 1.42,
      brightness: 1.03,
      gamma: 0.94,
    );

    final thresholded = _binarizeForOcr(grayscaleContrast);

    return [
      _WebOcrImageVariant(label: 'base', bytes: encode(base)),
      _WebOcrImageVariant(label: 'contrast', bytes: encode(contrast)),
      _WebOcrImageVariant(label: 'sharpened', bytes: encode(sharpened)),
      _WebOcrImageVariant(
        label: 'grayscale_contrast',
        bytes: encode(grayscaleContrast),
      ),
      _WebOcrImageVariant(label: 'thresholded', bytes: encode(thresholded)),
    ];
  }

  img.Image _binarizeForOcr(img.Image image) {
    final out = img.copyResize(image, width: image.width, height: image.height);
    var total = 0;
    var count = 0;

    for (var y = 0; y < out.height; y += 2) {
      for (var x = 0; x < out.width; x += 2) {
        total += out.getPixel(x, y).r.toInt();
        count++;
      }
    }

    final average = count == 0 ? 180 : (total / count).round();
    final threshold = average.clamp(150, 205);

    for (var y = 0; y < out.height; y++) {
      for (var x = 0; x < out.width; x++) {
        final pixel = out.getPixel(x, y);
        final luminance = pixel.r.toInt();
        final value = luminance >= threshold ? 255 : 0;
        out.setPixelRgba(x, y, value, value, value, 255);
      }
    }

    return out;
  }

  img.Image _cropRelative(
    img.Image image, {
    required double x,
    required double y,
    required double w,
    required double h,
  }) {
    final left = (image.width * x).round().clamp(0, image.width - 1);
    final top = (image.height * y).round().clamp(0, image.height - 1);
    final width =
        (image.width * w).round().clamp(1, image.width - left);
    final height =
        (image.height * h).round().clamp(1, image.height - top);
    return img.copyCrop(image, x: left, y: top, width: width, height: height);
  }

  List<Uint8List> _buildZoneVariants(img.Image zone) {
    final variants = <Uint8List>[];

    img.Image prepare(img.Image source) {
      var out = source;
      if (out.width < 1200) {
        out = img.copyResize(out, width: 1200);
      }
      return out;
    }

    Uint8List encode(img.Image image, {int quality = 95}) {
      return Uint8List.fromList(img.encodePng(image, level: 1));
    }

    final base = prepare(zone);
    final gray = img.grayscale(base);
    final sharpened = _sharpenForOcr(base);
    final highContrast = img.adjustColor(
      gray,
      contrast: 1.55,
      brightness: 1.04,
      gamma: 0.92,
    );
    final threshold = _binarizeForOcr(highContrast);

    variants.add(encode(base));
    variants.add(encode(sharpened));
    variants.add(encode(highContrast));
    variants.add(encode(threshold));
    return variants;
  }

  img.Image _sharpenForOcr(img.Image image) {
    final source = img.copyResize(image, width: image.width, height: image.height);
    final blurred = img.gaussianBlur(source, radius: 1);
    final out = img.Image.from(source);

    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final src = source.getPixel(x, y);
        final blur = blurred.getPixel(x, y);

        int boost(int original, int soft) {
          return (original + ((original - soft) * 1.35))
              .round()
              .clamp(0, 255);
        }

        out.setPixelRgba(
          x,
          y,
          boost(src.r.toInt(), blur.r.toInt()),
          boost(src.g.toInt(), blur.g.toInt()),
          boost(src.b.toInt(), blur.b.toInt()),
          src.a.toInt(),
        );
      }
    }

    return out;
  }

  String _pickBestZoneText(String field, List<String> candidates) {
    final cleaned = candidates
        .map((e) => _sanitizeZoneText(field, e))
        .where((e) => e.isNotEmpty)
        .toList();
    if (cleaned.isEmpty) return '';

    switch (field) {
      case 'clave':
        return _extractBestToken(
              RegExp(r'[A-Z0-9]{17,19}'),
              cleaned,
            ) ??
            '';
      case 'curp':
        return _extractBestToken(
              RegExp(r'[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}'),
              cleaned,
            ) ??
            '';
      case 'fechaNacimiento':
        return _extractBestToken(
              RegExp(r'\b\d{2}[/-]\d{2}[/-]\d{4}\b'),
              cleaned,
            ) ??
            cleaned.first;
      case 'seccion':
        return _extractBestToken(RegExp(r'\b\d{3,4}\b'), cleaned) ?? '';
      case 'vigencia':
        return _extractBestToken(
              RegExp(r'\b20\d{2}\s*[-–]\s*20\d{2}\b'),
              cleaned,
            ) ??
            '';
      case 'sexo':
        for (final candidate in cleaned) {
          final normalized = candidate.toUpperCase().replaceAll(' ', '');
          if (normalized.contains('SEXOH') || normalized == 'H') return 'H';
          if (normalized.contains('SEXOM') || normalized == 'M') return 'M';
        }
        return '';
      case 'name':
      case 'domicilio':
        cleaned.sort((a, b) => b.replaceAll('\n', ' ').length.compareTo(a.replaceAll('\n', ' ').length));
        return cleaned.first;
      default:
        return cleaned.first;
    }
  }

  String? _extractBestToken(RegExp regex, List<String> candidates) {
    String? best;
    for (final candidate in candidates) {
      final upper = candidate.toUpperCase();
      for (final match in regex.allMatches(upper)) {
        final token = match.group(0)?.trim();
        if (token == null || token.isEmpty) continue;
        if (best == null || token.length > best.length) {
          best = token;
        }
      }
    }
    return best;
  }

  String _sanitizeZoneText(String field, String value) {
    var text = value.replaceAll('\r', '\n').trim().toUpperCase();

    switch (field) {
      case 'name':
        text = text.replaceAll(RegExp(r'\bN0MBRE\b|\bNOMBRE\b'), '');
        break;
      case 'domicilio':
        text = text.replaceAll(RegExp(r'\bD0MICILI0\b|\bDOMICILIO\b'), '');
        break;
      case 'clave':
        text = text.replaceAll(
          RegExp(r'\bCLAVE\s*DE\s*ELECT[O0]R\b|\bCLAVE\b'),
          '',
        );
        break;
      case 'curp':
        text = text.replaceAll(RegExp(r'\bCURP\b'), '');
        break;
      case 'fechaNacimiento':
        text = text.replaceAll(
          RegExp(r'\bFECHA\s*DE\s*NACIMIENTO\b'),
          '',
        );
        break;
      case 'seccion':
        text = text.replaceAll(RegExp(r'\bSECCI[O0]N\b'), '');
        break;
      case 'vigencia':
        text = text.replaceAll(RegExp(r'\bVIGENCIA\b'), '');
        break;
      case 'sexo':
        text = text.replaceAll(RegExp(r'\bSEXO\b'), '');
        break;
    }

    return text
        .replaceAllMapped(RegExp(r'[ \t]+'), (_) => ' ')
        .replaceAll(RegExp(r'\n+'), '\n')
        .trim();
  }

  String _buildSyntheticIneText(Map<String, String> zoneTexts) {
    final lines = <String>[];

    void addBlock(String label, String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      lines.add(label);
      lines.add(trimmed);
    }

    addBlock('NOMBRE', zoneTexts['name'] ?? '');
    addBlock('DOMICILIO', zoneTexts['domicilio'] ?? '');
    addBlock('CLAVE DE ELECTOR', zoneTexts['clave'] ?? '');
    addBlock('CURP', zoneTexts['curp'] ?? '');
    addBlock('FECHA DE NACIMIENTO', zoneTexts['fechaNacimiento'] ?? '');
    addBlock('SECCION', zoneTexts['seccion'] ?? '');
    addBlock('VIGENCIA', zoneTexts['vigencia'] ?? '');
    addBlock('SEXO', zoneTexts['sexo'] ?? '');

    return lines.join('\n');
  }

  Map<String, String> _mergePreferredFields(
    Map<String, String> base,
    Map<String, String> overlay, {
    required List<String> preferredKeys,
  }) {
    final merged = Map<String, String>.from(base);

    for (final key in preferredKeys) {
      final candidate = (overlay[key] ?? '').trim();
      if (candidate.isEmpty) continue;

      final current = (merged[key] ?? '').trim();
      if (current.isEmpty ||
          _preferOverlayValue(key, candidate, current)) {
        merged[key] = candidate;
      }
    }

    if ((merged['claveElectoral'] ?? '').isNotEmpty) {
      merged['claveElector'] = merged['claveElectoral']!;
    }
    if ((merged['seccionElectoral'] ?? '').isNotEmpty) {
      merged['seccion'] = merged['seccionElectoral']!;
    }

    return merged;
  }

  bool _preferOverlayValue(String key, String candidate, String current) {
    switch (key) {
      case 'claveElectoral':
      case 'claveElector':
        return candidate.length >= current.length;
      case 'curp':
        return candidate.length >= current.length;
      case 'fechaNacimiento':
        return RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(candidate) &&
            !RegExp(r'^\d{2}/\d{2}/\d{4}$').hasMatch(current);
      case 'seccionElectoral':
      case 'seccion':
      case 'vigencia':
      case 'sexo':
        return true;
      case 'nombre':
      case 'apellidoPaterno':
      case 'apellidoMaterno':
      case 'direccion':
      case 'municipio':
      case 'estado':
      case 'codigoPostal':
        return candidate.length >= current.length;
      default:
        return false;
    }
  }

  Map<String, String> _mergeVariantResults(List<_WebOcrVariantResult> results) {
    final merged = Map<String, String>.from(results.first.parsed);
    final bestScores = Map<String, double>.from(results.first.validation.confidence);

    const mirroredKeys = {
      'claveElector': 'claveElectoral',
      'seccion': 'seccionElectoral',
    };

    for (final result in results.skip(1)) {
      result.validation.confidence.forEach((key, score) {
        final sourceKey = mirroredKeys[key] ?? key;
        final existingScore = bestScores[sourceKey] ?? 0.0;
        final candidateValue =
            (result.validation.normalizedData[sourceKey] ??
                    result.parsed[sourceKey] ??
                    '')
                .trim();

        if (candidateValue.isEmpty) {
          return;
        }

        final currentValue = (merged[sourceKey] ?? '').trim();
        final shouldReplace =
            score > existingScore + 0.05 ||
            currentValue.isEmpty ||
            (score >= existingScore &&
                _preferLongerFieldValue(sourceKey, candidateValue, currentValue));

        if (!shouldReplace) {
          return;
        }

        merged[sourceKey] = candidateValue;
        bestScores[sourceKey] = score;
      });
    }

    if ((merged['claveElectoral'] ?? '').isNotEmpty) {
      merged['claveElector'] = merged['claveElectoral']!;
    }
    if ((merged['seccionElectoral'] ?? '').isNotEmpty) {
      merged['seccion'] = merged['seccionElectoral']!;
    }

    return merged;
  }

  bool _preferLongerFieldValue(
    String key,
    String candidate,
    String current,
  ) {
    if (current.isEmpty) return true;
    if (candidate == current) return false;

    switch (key) {
      case 'nombre':
      case 'apellidoPaterno':
      case 'apellidoMaterno':
      case 'direccion':
      case 'municipio':
      case 'estado':
        return candidate.length > current.length;
      default:
        return false;
    }
  }

  void _wipeBytes(Uint8List buffer) {
    if (buffer.isEmpty) return;
    buffer.fillRange(0, buffer.length, 0);
  }

  String _resolveWebAssetUrl(String relativePath) {
    return Uri.base.resolve(relativePath).toString();
  }

  Future<String> _runWebOcr(Uint8List bytes) async {
    await _ensureTesseractLoaded();

    final tesseract = js_util.getProperty(html.window, 'Tesseract');
    if (tesseract == null) {
      throw StateError('Tesseract no esta disponible en Web.');
    }

    final mimeType = _guessImageMimeType(bytes);
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final recognizePromise = js_util.callMethod(
      tesseract,
      'recognize',
      [
        dataUrl,
        'spa',
        {
          'workerPath': _resolveWebAssetUrl(_tesseractWorkerAsset),
          'langPath': _resolveWebAssetUrl(_tesseractLangAsset),
          'corePath': _resolveWebAssetUrl(_tesseractCoreAsset),
        },
      ],
    );
    final result = await js_util.promiseToFuture<Object?>(recognizePromise);
    final data = js_util.getProperty(result!, 'data');
    final text = js_util.getProperty(data, 'text');
    return (text ?? '').toString().trim();
  }

  String _guessImageMimeType(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    return 'image/jpeg';
  }

  Future<void> _ensureTesseractLoaded() {
    final existing = js_util.getProperty<Object?>(html.window, 'Tesseract');
    if (existing != null) {
      return Future.value();
    }

    final pending = _tesseractLoader;
    if (pending != null) {
      return pending;
    }

    final completer = Completer<void>();
    _tesseractLoader = completer.future;

    final script = html.ScriptElement()
      ..src = _resolveWebAssetUrl(_tesseractScriptAsset)
      ..defer = true
      ..async = true;

    late html.EventListener onLoad;
    late html.EventListener onError;

    onLoad = (_) {
      script.removeEventListener('load', onLoad);
      script.removeEventListener('error', onError);
      final loaded = js_util.getProperty<Object?>(html.window, 'Tesseract');
      if (loaded == null) {
        _tesseractLoader = null;
        completer.completeError(
          StateError('No se pudo inicializar el OCR web.'),
        );
        return;
      }
      completer.complete();
    };

    onError = (_) {
      script.removeEventListener('load', onLoad);
      script.removeEventListener('error', onError);
      _tesseractLoader = null;
      completer.completeError(
        StateError(
          'No se pudo cargar el motor OCR web. Si no hay conexion, la captura OCR web no estara disponible.',
        ),
      );
    };

    script.addEventListener('load', onLoad);
    script.addEventListener('error', onError);
    html.document.head?.append(script);

    return completer.future;
  }

  Future<void> _ensureVisionLoaded() {
    final existing =
        js_util.getProperty<Object?>(html.window, 'Guardianes4TVision');
    if (existing != null) {
      return Future.value();
    }

    final pending = _visionLoader;
    if (pending != null) {
      return pending;
    }

    final completer = Completer<void>();
    _visionLoader = completer.future;

    final script = html.ScriptElement()
      ..src = _resolveWebAssetUrl(_visionScriptAsset)
      ..defer = true
      ..async = true;

    late html.EventListener onLoad;
    late html.EventListener onError;

    onLoad = (_) {
      script.removeEventListener('load', onLoad);
      script.removeEventListener('error', onError);
      final loaded =
          js_util.getProperty<Object?>(html.window, 'Guardianes4TVision');
      if (loaded == null) {
        _visionLoader = null;
        completer.completeError(
          StateError('No se pudo inicializar el motor de vision web.'),
        );
        return;
      }
      completer.complete();
    };

    onError = (_) {
      script.removeEventListener('load', onLoad);
      script.removeEventListener('error', onError);
      _visionLoader = null;
      completer.completeError(
        StateError('No se pudo cargar el motor de vision web.'),
      );
    };

    script.addEventListener('load', onLoad);
    script.addEventListener('error', onError);
    html.document.head?.append(script);

    return completer.future;
  }

  void _stopCamera() {
    _analysisTimer?.cancel();
    final stream = _mediaStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
    }
    _videoElement?.pause();
    _videoElement?.srcObject = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Escaneo de INE'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Captura automatica de INE',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _message,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.45,
                        color: Color(0xFF4B5563),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_cameraReady)
                                  HtmlElementView(viewType: _viewId)
                                else
                                  Container(
                                    color: const Color(0xFF111827),
                                    alignment: Alignment.center,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const CircularProgressIndicator(
                                          color: Colors.white,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          _initializingCamera
                                              ? 'Abriendo camara...'
                                              : 'Camara no disponible',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(24),
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: math.min(
                                          MediaQuery.of(context).size.width *
                                              0.72,
                                          360,
                                        ),
                                        height: 220,
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(18),
                                          border: Border.all(
                                            color: const Color(0xFF8E1F2F),
                                            width: 3,
                                          ),
                                          color: Colors.transparent,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: (!_cameraReady || _processing)
                                    ? null
                                    : _captureFromLiveCamera,
                                icon: const Icon(Icons.camera_alt_outlined),
                                label: const Text('Capturar ahora'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _processing ? null : _pickFromGallery,
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text('Galeria'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'La captura automatica se activa cuando detectamos la INE centrada, enfocada y estable para enviar un recorte mas limpio al OCR.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF6B7280),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebOcrImageVariant {
  const _WebOcrImageVariant({
    required this.label,
    required this.bytes,
  });

  final String label;
  final Uint8List bytes;
}

class _WebOcrVariantResult {
  const _WebOcrVariantResult({
    required this.label,
    required this.rawText,
    required this.parsed,
    required this.validation,
  });

  final String label;
  final String rawText;
  final Map<String, String> parsed;
  final OcrValidationResult validation;
}

class _BestWebOcrResult {
  const _BestWebOcrResult({
    required this.rawText,
    required this.parsed,
    required this.validation,
  });

  final String rawText;
  final Map<String, String> parsed;
  final OcrValidationResult validation;
}
