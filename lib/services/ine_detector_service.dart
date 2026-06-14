import 'package:flutter/foundation.dart';

class DetectionBox {
  final String label;
  final double confidence;
  final double left;
  final double top;
  final double right;
  final double bottom;

  DetectionBox({
    required this.label,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  double get width => right - left;
  double get height => bottom - top;

  @override
  String toString() {
    return 'DetectionBox(label: $label, conf: $confidence, left: $left, top: $top, right: $right, bottom: $bottom)';
  }
}

class DetectionCropResult {
  final String? fullImagePath;
  final Map<String, String> cropsByLabel;
  final List<DetectionBox> detections;

  DetectionCropResult({
    required this.fullImagePath,
    required this.cropsByLabel,
    required this.detections,
  });
}

class IneDetectorService {
  Future<void> init() async {
    debugPrint(
      '[INE DETECTOR] Detector local deshabilitado en esta compilacion; se usara el fallback OCR por zonas fijas.',
    );
  }

  Future<DetectionCropResult> detectAndCrop(String imagePath) async {
    await init();
    return DetectionCropResult(
      fullImagePath: imagePath,
      cropsByLabel: const {},
      detections: const [],
    );
  }

  Future<void> dispose() async {}
}
