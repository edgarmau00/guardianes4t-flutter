import 'dart:async';
import 'dart:convert';
import 'dart:js_util' as js_util;
import 'dart:typed_data';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../../app/routes.dart';
import '../../services/ocr_validation_service.dart';
import '../../services/web_ocr_parser.dart';

class ScanIneScreen extends StatefulWidget {
  const ScanIneScreen({super.key});

  @override
  State<ScanIneScreen> createState() => _ScanIneScreenState();
}

class _ScanIneScreenState extends State<ScanIneScreen> {
  static const Duration _ocrTimeout = Duration(seconds: 45);

  final ImagePicker _imagePicker = ImagePicker();
  bool _processing = false;
  String _message =
      'Desde Safari puedes tomar la foto de la INE o subirla desde tu galeria.';

  Future<void> _pickFromCamera() async {
    await _captureAndProcess(ImageSource.camera);
  }

  Future<void> _pickFromGallery() async {
    await _captureAndProcess(ImageSource.gallery);
  }

  Future<void> _captureAndProcess(ImageSource source) async {
    if (_processing) return;

    try {
      setState(() {
        _processing = true;
        _message = 'Abriendo camara...';
      });

      final picked = await _imagePicker.pickImage(
        source: source,
        imageQuality: 92,
        maxWidth: 1800,
      );

      if (picked == null) {
        if (!mounted) return;
        setState(() {
          _processing = false;
          _message =
              'Desde Safari puedes tomar la foto de la INE o subirla desde tu galeria.';
        });
        return;
      }

      final bytes = await picked.readAsBytes();
      final previewBytes = _normalizeForPreview(bytes);

      if (!mounted) return;
      setState(() {
        _message = 'Leyendo texto con OCR web...';
      });

      final rawText = await _runWebOcr(previewBytes).timeout(_ocrTimeout);
      final parsed = WebOcrParser().parse(rawText);
      final validation = OcrValidationService().validate(parsed);
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
          'processingMode': 'web_tesseract',
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
    }
  }

  Uint8List _normalizeForPreview(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    final normalized = decoded.width > 1800
        ? img.copyResize(decoded, width: 1800)
        : decoded;

    return Uint8List.fromList(img.encodeJpg(normalized, quality: 90));
  }

  Future<String> _runWebOcr(Uint8List bytes) async {
    final tesseract = js_util.getProperty(html.window, 'Tesseract');
    if (tesseract == null) {
      throw StateError('Tesseract no esta disponible en Web.');
    }

    final dataUrl = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    final recognizePromise = js_util.callMethod(
      tesseract,
      'recognize',
      [dataUrl, 'spa'],
    );
    final result = await js_util.promiseToFuture<Object?>(recognizePromise);
    final data = js_util.getProperty(result!, 'data');
    final text = js_util.getProperty(data, 'text');
    return (text ?? '').toString().trim();
  }

  @override
  Widget build(BuildContext context) {
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
                      'Captura con INE desde Safari',
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
              const SizedBox(height: 24),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(22),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.badge_rounded,
                          size: 72,
                          color: Color(0xFF7A0C0C),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'Toma la foto por ambos lados si necesitas validar mejor los datos antes de continuar.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.45,
                            color: Color(0xFF374151),
                          ),
                        ),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _processing ? null : _pickFromCamera,
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: Text(
                              _processing ? 'Procesando...' : 'Tomar foto',
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _processing ? null : _pickFromGallery,
                            icon: const Icon(Icons.photo_library_outlined),
                            label: const Text('Elegir desde galeria'),
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
