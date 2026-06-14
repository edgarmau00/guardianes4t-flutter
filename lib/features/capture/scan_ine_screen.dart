import 'package:doc_scan_flutter/doc_scan.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'dart:io';

import '../../app/routes.dart';
import '../../services/ocr_service.dart';
import '../../services/ocr_validation_service.dart';

class ScanIneScreen extends StatefulWidget {
  const ScanIneScreen({super.key});

  @override
  State<ScanIneScreen> createState() => _ScanIneScreenState();
}

class _ScanIneScreenState extends State<ScanIneScreen> {
  static const int _qualityCheckMaxWidth = 960;
  static const Duration _ocrTimeout = Duration(seconds: 28);

  bool _processing = false;
  bool _scannerOpened = false;
  String _processingMessage = 'Procesando datos...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scannerOpened) return;
      _scannerOpened = true;
      _scanWithDocumentScanner();
    });
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

      if (avgBrightness < 38) {
        return const _ImageQualityCheck(
          warningMessage: 'La imagen se ve oscura. La lectura podria bajar.',
        );
      }

      if (avgBrightness > 242) {
        return const _ImageQualityCheck(
          warningMessage:
              'La imagen tiene mucho brillo o reflejo. La lectura podria bajar.',
        );
      }

      if (avgEdge < 8) {
        return const _ImageQualityCheck(
          warningMessage:
              'La imagen se ve borrosa. Intentaremos leerla, pero podria fallar.',
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
    if (_processing) return;

    try {
      setState(() {
        _processing = true;
        _processingMessage = 'Abriendo escaner inteligente...';
      });

      final result = await DocumentScanner.scan(format: DocScanFormat.jpeg);
      if (result == null || result.isEmpty) {
        if (!mounted) return;
        setState(() => _processing = false);
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
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error al usar el escaner. Intenta de nuevo.'),
        ),
      );
    }
  }

  Future<void> _processImagePath(String imagePath) async {
    if (!mounted) return;

    setState(() {
      _processing = true;
      _processingMessage = 'Validando calidad de imagen...';
    });

    final qualityCheck = await _validateImageQuality(imagePath);
    if (qualityCheck.blockingMessage != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(qualityCheck.blockingMessage!)),
      );
      setState(() => _processing = false);
      return;
    }

    if (qualityCheck.warningMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(qualityCheck.warningMessage!)),
      );
    }

    if (!mounted) return;

    setState(() {
      _processingMessage = 'Corrigiendo imagen y leyendo datos...';
    });

    final ocr = OcrService();
    try {
      final rawResult = await ocr.scanIne(imagePath).timeout(_ocrTimeout);
      final validation = OcrValidationService().validate(rawResult);
      final data = Map<String, dynamic>.from(validation.normalizedData);

      data['processingMode'] = rawResult['processingMode'] ?? 'ocr_only';
      data['globalConfidence'] = validation.globalConfidence;

      if (!mounted) return;

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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo completar la lectura. Intenta de nuevo con una foto mas estable.',
          ),
        ),
      );
    } finally {
      await ocr.dispose();
      if (mounted) {
        setState(() => _processing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
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
            ),
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
