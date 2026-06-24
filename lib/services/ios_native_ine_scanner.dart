import 'dart:io';

import 'package:flutter/services.dart';

class IosNativeIneScanResult {
  final String imagePath;
  final String rawText;
  final String source;

  const IosNativeIneScanResult({
    required this.imagePath,
    required this.rawText,
    required this.source,
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

    if (imagePath.isEmpty) return null;

    return IosNativeIneScanResult(
      imagePath: imagePath,
      rawText: rawText,
      source: source,
    );
  }
}
