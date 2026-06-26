import 'dart:io';

import 'package:flutter/services.dart';

class IosNativeIneScanResult {
  final String imagePath;
  final String rawText;
  final String source;
  final Map<String, String> structuredData;

  const IosNativeIneScanResult({
    required this.imagePath,
    required this.rawText,
    required this.source,
    this.structuredData = const {},
  });
}

class IosNativeIneScanner {
  static const MethodChannel _channel = MethodChannel(
    'guardianes4t/ios_native_ine_scanner',
  );

  Future<IosNativeIneScanResult?> scanIne() async {
    if (!Platform.isIOS) return null;

    final raw = await _channel.invokeMethod<dynamic>('scanIne');
    if (raw is! Map) return null;

    final imagePath = (raw['imagePath'] ?? '').toString();
    final rawText = (raw['rawText'] ?? '').toString();
    final source = (raw['source'] ?? 'ios_visionkit_native').toString();
    final structuredData = _parseStructuredData(raw['structuredData']);

    if (imagePath.isEmpty) return null;

    return IosNativeIneScanResult(
      imagePath: imagePath,
      rawText: rawText,
      source: source,
      structuredData: structuredData,
    );
  }

  Future<IosNativeIneScanResult?> processCapturedImage(String imagePath) async {
    if (!Platform.isIOS || imagePath.trim().isEmpty) return null;

    final raw = await _channel.invokeMethod<dynamic>('processCapturedIne', {
      'imagePath': imagePath,
    });
    if (raw is! Map) return null;

    final processedImagePath = (raw['imagePath'] ?? imagePath).toString();
    final rawText = (raw['rawText'] ?? '').toString();
    final source = (raw['source'] ?? 'ios_vision_still_image').toString();
    final structuredData = _parseStructuredData(raw['structuredData']);

    if (processedImagePath.isEmpty) return null;

    return IosNativeIneScanResult(
      imagePath: processedImagePath,
      rawText: rawText,
      source: source,
      structuredData: structuredData,
    );
  }

  Map<String, String> _parseStructuredData(dynamic raw) {
    if (raw is! Map) return const {};

    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString().trim() ?? '';
      if (key.isEmpty) continue;
      result[key] = (entry.value ?? '').toString().trim();
    }
    return result;
  }
}
