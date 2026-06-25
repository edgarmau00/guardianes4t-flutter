import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:html' as html;

import 'package:image/image.dart' as img;

class WebDocumentDetector {
  static const double _targetAspect = 1.58;
  static const double _minAreaRatio = 0.20;
  static const double _maxAreaRatio = 0.84;
  static const double _maxAspectError = 0.32;
  static const double _maxCenterDistance = 0.13;
  static const double _minSharpness = 22.0;
  static const double _minBrightness = 84.0;
  static const double _maxBrightness = 206.0;
  static const double _maxHighlightRatio = 0.085;
  static const double _maxStabilityDelta = 0.070;
  static const double _minContrast = 24.0;
  static const double _minBorderStrength = 15.0;
  static const double _minOutsideDelta = 7.0;

  DocumentFrameAnalysis analyzeFrame({
    required html.VideoElement video,
    required html.CanvasElement canvas,
    DocumentRect? previousRect,
  }) {
    final context = canvas.context2D;
    context.drawImageScaled(video, 0, 0, canvas.width!, canvas.height!);

    final imageData =
        context.getImageData(0, 0, canvas.width!, canvas.height!).data;

    final rect = _detectDocumentRect(
      bytes: imageData,
      width: canvas.width!,
      height: canvas.height!,
    );

    if (rect == null) {
      return const DocumentFrameAnalysis(
        message: 'Centra la INE completa dentro del recuadro.',
        readyForAutoCapture: false,
      );
    }

    final metrics = _measureInsideRect(
      bytes: imageData,
      width: canvas.width!,
      height: canvas.height!,
      rect: rect,
    );

    final outsideMetrics = _measureOutsideRect(
      bytes: imageData,
      width: canvas.width!,
      height: canvas.height!,
      rect: rect,
    );

    final aspectError = (rect.aspectRatio - _targetAspect).abs();
    final centerDistance = rect.centerDistanceFromFrameCenter;
    final stabilityDelta = previousRect == null
        ? 0.0
        : rect.distanceFrom(previousRect);

    if (rect.areaRatio < _minAreaRatio) {
      return DocumentFrameAnalysis(
        message: 'Acerca mas la INE al centro de la camara.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (rect.areaRatio > _maxAreaRatio) {
      return DocumentFrameAnalysis(
        message: 'Aleja un poco la INE para capturarla completa.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (aspectError > _maxAspectError) {
      return DocumentFrameAnalysis(
        message: 'Endereza la INE para verla mas rectangular.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (centerDistance > _maxCenterDistance) {
      return DocumentFrameAnalysis(
        message: 'Mueve la INE un poco hacia el centro.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (metrics.brightness < _minBrightness) {
      return DocumentFrameAnalysis(
        message: 'Falta luz. Acerca la INE a una zona mas iluminada.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (metrics.brightness > _maxBrightness ||
        metrics.highlightRatio > _maxHighlightRatio) {
      return DocumentFrameAnalysis(
        message: 'Hay reflejo o demasiada luz. Inclina un poco la INE.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (metrics.contrast < _minContrast) {
      return DocumentFrameAnalysis(
        message: 'La INE se ve plana. Acercala y evita fondos similares.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (metrics.borderStrength < _minBorderStrength) {
      return DocumentFrameAnalysis(
        message: 'Marca mejor los bordes de la INE dentro del recuadro.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if ((metrics.brightness - outsideMetrics.brightness).abs() <
        _minOutsideDelta) {
      return DocumentFrameAnalysis(
        message: 'Se confunde con el fondo. Cambia un poco el angulo o el fondo.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (metrics.sharpness < _minSharpness) {
      return DocumentFrameAnalysis(
        message: 'Mantente quieto un momento para mejorar el enfoque.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    if (stabilityDelta > _maxStabilityDelta) {
      return DocumentFrameAnalysis(
        message: 'No muevas la INE. Esperando estabilidad para capturar.',
        readyForAutoCapture: false,
        rect: rect,
      );
    }

    return DocumentFrameAnalysis(
      message: 'INE detectada correctamente. Capturando automaticamente...',
      readyForAutoCapture: true,
      rect: rect,
    );
  }

  Uint8List captureDocument({
    required html.VideoElement video,
    required DocumentRect? detectedRect,
  }) {
    final canvas = html.CanvasElement(
      width: video.videoWidth,
      height: video.videoHeight,
    );
    final context = canvas.context2D;
    context.drawImageScaled(video, 0, 0, canvas.width!, canvas.height!);

    final dataUrl = canvas.toDataUrl('image/jpeg', 0.96);
    final bytes = UriData.parse(dataUrl).contentAsBytes();
    return captureDocumentFromBytes(
      imageBytes: bytes,
      detectedRect: detectedRect,
      sourceWidth: video.videoWidth.toDouble(),
      sourceHeight: video.videoHeight.toDouble(),
    );
  }

  Uint8List captureDocumentFromBytes({
    required Uint8List imageBytes,
    required DocumentRect? detectedRect,
    double? sourceWidth,
    double? sourceHeight,
  }) {
    final decoded = img.decodeImage(imageBytes);
    if (decoded == null) {
      return imageBytes;
    }

    final resolvedRect = detectedRect ?? _detectDocumentRectOnImage(decoded);

    if (resolvedRect == null) {
      var enhanced = _enhanceForOcr(decoded);
      if (enhanced.width > 2400) {
        enhanced = img.copyResize(enhanced, width: 2400);
      }
      return Uint8List.fromList(img.encodePng(enhanced, level: 2));
    }

    var crop = resolvedRect
        .scaleTo(
          sourceWidth: sourceWidth ?? decoded.width.toDouble(),
          sourceHeight: sourceHeight ?? decoded.height.toDouble(),
        )
        .inflatePercent(0.05);

    crop = _refineRectOnDecodedImage(decoded, crop);

    final cropX = crop.left.round().clamp(0, decoded.width - 1);
    final cropY = crop.top.round().clamp(0, decoded.height - 1);
    final cropWidth = crop.width.round().clamp(1, decoded.width - cropX);
    final cropHeight = crop.height.round().clamp(1, decoded.height - cropY);

    var cropped = img.copyCrop(
      decoded,
      x: cropX,
      y: cropY,
      width: cropWidth,
      height: cropHeight,
    );

    if (cropped.width < cropped.height) {
      cropped = img.copyRotate(cropped, angle: 90);
    }

    cropped = _trimSolidMargins(cropped);
    cropped = _enhanceForOcr(cropped);

    if (cropped.width > 2400) {
      cropped = img.copyResize(cropped, width: 2400);
    }

    return Uint8List.fromList(img.encodePng(cropped, level: 2));
  }

  DocumentRect? _detectDocumentRectOnImage(img.Image image) {
    final rgba = Uint8ClampedList.fromList(
      image.getBytes(order: img.ChannelOrder.rgba),
    );
    return _detectDocumentRect(
      bytes: rgba,
      width: image.width,
      height: image.height,
    );
  }

  DocumentRect? _detectDocumentRect({
    required Uint8ClampedList bytes,
    required int width,
    required int height,
  }) {
    if (width < 40 || height < 40) return null;

    final leftBound = (width * 0.08).round();
    final rightBound = (width * 0.92).round();
    final topBound = (height * 0.12).round();
    final bottomBound = (height * 0.88).round();

    final verticalProfile = List<double>.filled(width, 0);
    final horizontalProfile = List<double>.filled(height, 0);

    int lumaAt(int x, int y) {
      final index = ((y * width) + x) * 4;
      final r = bytes[index];
      final g = bytes[index + 1];
      final b = bytes[index + 2];
      return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
    }

    for (var y = topBound; y < bottomBound - 2; y += 2) {
      for (var x = leftBound; x < rightBound - 2; x += 2) {
        final current = lumaAt(x, y);
        final dx = (current - lumaAt(x + 2, y)).abs();
        final dy = (current - lumaAt(x, y + 2)).abs();
        verticalProfile[x] += dx;
        horizontalProfile[y] += dy;
      }
    }

    final smoothVertical = _smooth(verticalProfile, radius: 8);
    final smoothHorizontal = _smooth(horizontalProfile, radius: 8);

    final coarseLeft = _findPeak(
      smoothVertical,
      start: leftBound,
      end: width ~/ 2,
      fallback: width * 0.18,
    );
    final coarseRight = _findPeak(
      smoothVertical,
      start: width ~/ 2,
      end: rightBound,
      fallback: width * 0.82,
    );
    final coarseTop = _findPeak(
      smoothHorizontal,
      start: topBound,
      end: height ~/ 2,
      fallback: height * 0.26,
    );
    final coarseBottom = _findPeak(
      smoothHorizontal,
      start: height ~/ 2,
      end: bottomBound,
      fallback: height * 0.74,
    );

    final left = _refineVerticalEdge(
      bytes: bytes,
      width: width,
      height: height,
      fromX: coarseLeft,
      direction: 1,
      top: coarseTop,
      bottom: coarseBottom,
    );
    final right = _refineVerticalEdge(
      bytes: bytes,
      width: width,
      height: height,
      fromX: coarseRight,
      direction: -1,
      top: coarseTop,
      bottom: coarseBottom,
    );
    final top = _refineHorizontalEdge(
      bytes: bytes,
      width: width,
      height: height,
      fromY: coarseTop,
      direction: 1,
      left: left,
      right: right,
    );
    final bottom = _refineHorizontalEdge(
      bytes: bytes,
      width: width,
      height: height,
      fromY: coarseBottom,
      direction: -1,
      left: left,
      right: right,
    );

    final rectWidth = (right - left).toDouble();
    final rectHeight = (bottom - top).toDouble();
    if (rectWidth < width * 0.30 || rectHeight < height * 0.20) {
      return null;
    }

    return DocumentRect.fromPixels(
      left: left.toDouble(),
      top: top.toDouble(),
      right: right.toDouble(),
      bottom: bottom.toDouble(),
      frameWidth: width.toDouble(),
      frameHeight: height.toDouble(),
    );
  }

  _RectMetrics _measureInsideRect({
    required Uint8ClampedList bytes,
    required int width,
    required int height,
    required DocumentRect rect,
  }) {
    final left = (rect.left * width).round().clamp(0, width - 2);
    final top = (rect.top * height).round().clamp(0, height - 2);
    final right = (rect.right * width).round().clamp(left + 1, width - 1);
    final bottom = (rect.bottom * height).round().clamp(top + 1, height - 1);

    int lumaAt(int x, int y) {
      final index = ((y * width) + x) * 4;
      final r = bytes[index];
      final g = bytes[index + 1];
      final b = bytes[index + 2];
      return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
    }

    double brightness = 0;
    double sharpness = 0;
    double varianceSum = 0;
    int highlights = 0;
    int total = 0;
    final samples = <int>[];

    for (var y = top; y < bottom - 2; y += 2) {
      for (var x = left; x < right - 2; x += 2) {
        final current = lumaAt(x, y);
        final dx = (current - lumaAt(x + 2, y)).abs();
        final dy = (current - lumaAt(x, y + 2)).abs();
        brightness += current;
        sharpness += (dx + dy);
        if (current > 245) highlights += 1;
        total += 1;
        samples.add(current);
      }
    }

    if (total == 0) {
      return const _RectMetrics(
        brightness: 0,
        sharpness: 0,
        highlightRatio: 0,
        contrast: 0,
        borderStrength: 0,
      );
    }

    final avgBrightness = brightness / total;
    for (final value in samples) {
      varianceSum += math.pow(value - avgBrightness, 2).toDouble();
    }

    return _RectMetrics(
      brightness: avgBrightness,
      sharpness: sharpness / total,
      highlightRatio: highlights / total,
      contrast: math.sqrt(varianceSum / total),
      borderStrength: _measureBorderStrength(
        bytes: bytes,
        width: width,
        height: height,
        left: left,
        top: top,
        right: right,
        bottom: bottom,
      ),
    );
  }

  _OutsideMetrics _measureOutsideRect({
    required Uint8ClampedList bytes,
    required int width,
    required int height,
    required DocumentRect rect,
  }) {
    final left = (rect.left * width).round().clamp(0, width - 2);
    final top = (rect.top * height).round().clamp(0, height - 2);
    final right = (rect.right * width).round().clamp(left + 1, width - 1);
    final bottom = (rect.bottom * height).round().clamp(top + 1, height - 1);

    int lumaAt(int x, int y) {
      final index = ((y * width) + x) * 4;
      final r = bytes[index];
      final g = bytes[index + 1];
      final b = bytes[index + 2];
      return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
    }

    final rings = <({int x, int y})>[];
    for (var x = math.max(0, left - 14); x <= math.min(width - 1, right + 14); x += 4) {
      final upY = math.max(0, top - 10);
      final downY = math.min(height - 1, bottom + 10);
      rings.add((x: x, y: upY));
      rings.add((x: x, y: downY));
    }
    for (var y = math.max(0, top - 14); y <= math.min(height - 1, bottom + 14); y += 4) {
      final leftX = math.max(0, left - 10);
      final rightX = math.min(width - 1, right + 10);
      rings.add((x: leftX, y: y));
      rings.add((x: rightX, y: y));
    }

    if (rings.isEmpty) {
      return const _OutsideMetrics(brightness: 0);
    }

    double brightness = 0;
    for (final point in rings) {
      brightness += lumaAt(point.x, point.y);
    }

    return _OutsideMetrics(brightness: brightness / rings.length);
  }

  double _measureBorderStrength({
    required Uint8ClampedList bytes,
    required int width,
    required int height,
    required int left,
    required int top,
    required int right,
    required int bottom,
  }) {
    int lumaAt(int x, int y) {
      final index = ((y * width) + x) * 4;
      final r = bytes[index];
      final g = bytes[index + 1];
      final b = bytes[index + 2];
      return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
    }

    double strength = 0;
    int count = 0;

    for (var y = top + 6; y < bottom - 6; y += 4) {
      final leftInner = lumaAt(left + 2, y);
      final leftOuter = lumaAt(math.max(0, left - 2), y);
      final rightInner = lumaAt(math.max(left + 1, right - 2), y);
      final rightOuter = lumaAt(math.min(width - 1, right + 1), y);
      strength += (leftInner - leftOuter).abs();
      strength += (rightInner - rightOuter).abs();
      count += 2;
    }

    for (var x = left + 6; x < right - 6; x += 4) {
      final topInner = lumaAt(x, top + 2);
      final topOuter = lumaAt(x, math.max(0, top - 2));
      final bottomInner = lumaAt(x, math.max(top + 1, bottom - 2));
      final bottomOuter = lumaAt(x, math.min(height - 1, bottom + 1));
      strength += (topInner - topOuter).abs();
      strength += (bottomInner - bottomOuter).abs();
      count += 2;
    }

    return count == 0 ? 0 : strength / count;
  }

  int _refineVerticalEdge({
    required Uint8ClampedList bytes,
    required int width,
    required int height,
    required int fromX,
    required int direction,
    required int top,
    required int bottom,
  }) {
    int lumaAt(int x, int y) {
      final index = ((y * width) + x) * 4;
      final r = bytes[index];
      final g = bytes[index + 1];
      final b = bytes[index + 2];
      return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
    }

    var bestX = fromX;
    var bestScore = 0.0;
    final start = (fromX - 18).clamp(2, width - 3);
    final end = (fromX + 18).clamp(2, width - 3);

    for (var x = start; x <= end; x++) {
      double score = 0;
      int count = 0;
      for (var y = top + 4; y < bottom - 4; y += 4) {
        final innerX = direction > 0 ? x + 2 : x - 2;
        final outerX = direction > 0 ? x - 2 : x + 2;
        if (innerX < 0 || innerX >= width || outerX < 0 || outerX >= width) {
          continue;
        }
        score += (lumaAt(innerX, y) - lumaAt(outerX, y)).abs();
        count += 1;
      }
      if (count == 0) continue;
      final avg = score / count;
      if (avg > bestScore) {
        bestScore = avg;
        bestX = x;
      }
    }

    return bestX;
  }

  int _refineHorizontalEdge({
    required Uint8ClampedList bytes,
    required int width,
    required int height,
    required int fromY,
    required int direction,
    required int left,
    required int right,
  }) {
    int lumaAt(int x, int y) {
      final index = ((y * width) + x) * 4;
      final r = bytes[index];
      final g = bytes[index + 1];
      final b = bytes[index + 2];
      return ((r * 299) + (g * 587) + (b * 114)) ~/ 1000;
    }

    var bestY = fromY;
    var bestScore = 0.0;
    final start = (fromY - 18).clamp(2, height - 3);
    final end = (fromY + 18).clamp(2, height - 3);

    for (var y = start; y <= end; y++) {
      double score = 0;
      int count = 0;
      for (var x = left + 4; x < right - 4; x += 4) {
        final innerY = direction > 0 ? y + 2 : y - 2;
        final outerY = direction > 0 ? y - 2 : y + 2;
        if (innerY < 0 || innerY >= height || outerY < 0 || outerY >= height) {
          continue;
        }
        score += (lumaAt(x, innerY) - lumaAt(x, outerY)).abs();
        count += 1;
      }
      if (count == 0) continue;
      final avg = score / count;
      if (avg > bestScore) {
        bestScore = avg;
        bestY = y;
      }
    }

    return bestY;
  }

  PixelDocumentRect _refineRectOnDecodedImage(
    img.Image image,
    PixelDocumentRect rect,
  ) {
    int lumaAt(int x, int y) {
      final pixel = image.getPixel(x, y);
      return ((pixel.r.toInt() * 299) +
              (pixel.g.toInt() * 587) +
              (pixel.b.toInt() * 114)) ~/
          1000;
    }

    var left = rect.left.round().clamp(0, image.width - 2);
    var top = rect.top.round().clamp(0, image.height - 2);
    var right = rect.right.round().clamp(left + 1, image.width - 1);
    var bottom = rect.bottom.round().clamp(top + 1, image.height - 1);

    int scanVertical(int from, int direction) {
      var best = from;
      var bestScore = 0.0;
      final start = math.max(2, from - 22);
      final end = math.min(image.width - 3, from + 22);
      for (var x = start; x <= end; x++) {
        double score = 0;
        int count = 0;
        for (var y = top + 8; y < bottom - 8; y += 6) {
          final inner = direction > 0 ? x + 2 : x - 2;
          final outer = direction > 0 ? x - 2 : x + 2;
          if (inner < 0 || inner >= image.width || outer < 0 || outer >= image.width) {
            continue;
          }
          score += (lumaAt(inner, y) - lumaAt(outer, y)).abs();
          count += 1;
        }
        if (count == 0) continue;
        final avg = score / count;
        if (avg > bestScore) {
          bestScore = avg;
          best = x;
        }
      }
      return best;
    }

    int scanHorizontal(int from, int direction) {
      var best = from;
      var bestScore = 0.0;
      final start = math.max(2, from - 22);
      final end = math.min(image.height - 3, from + 22);
      for (var y = start; y <= end; y++) {
        double score = 0;
        int count = 0;
        for (var x = left + 8; x < right - 8; x += 6) {
          final inner = direction > 0 ? y + 2 : y - 2;
          final outer = direction > 0 ? y - 2 : y + 2;
          if (inner < 0 || inner >= image.height || outer < 0 || outer >= image.height) {
            continue;
          }
          score += (lumaAt(x, inner) - lumaAt(x, outer)).abs();
          count += 1;
        }
        if (count == 0) continue;
        final avg = score / count;
        if (avg > bestScore) {
          bestScore = avg;
          best = y;
        }
      }
      return best;
    }

    left = scanVertical(left, 1);
    right = scanVertical(right, -1);
    top = scanHorizontal(top, 1);
    bottom = scanHorizontal(bottom, -1);

    return PixelDocumentRect(
      left: left.toDouble(),
      top: top.toDouble(),
      right: right.toDouble(),
      bottom: bottom.toDouble(),
    );
  }

  img.Image _trimSolidMargins(img.Image image) {
    if (image.width < 50 || image.height < 50) return image;

    int lumaAt(int x, int y) {
      final pixel = image.getPixel(x, y);
      return ((pixel.r.toInt() * 299) +
              (pixel.g.toInt() * 587) +
              (pixel.b.toInt() * 114)) ~/
          1000;
    }

    double lineVarianceVertical(int x) {
      double sum = 0;
      double sum2 = 0;
      int count = 0;
      for (var y = 0; y < image.height; y += 6) {
        final value = lumaAt(x, y).toDouble();
        sum += value;
        sum2 += value * value;
        count++;
      }
      if (count == 0) return 0;
      final mean = sum / count;
      return math.sqrt(math.max(0, (sum2 / count) - (mean * mean)));
    }

    double lineVarianceHorizontal(int y) {
      double sum = 0;
      double sum2 = 0;
      int count = 0;
      for (var x = 0; x < image.width; x += 6) {
        final value = lumaAt(x, y).toDouble();
        sum += value;
        sum2 += value * value;
        count++;
      }
      if (count == 0) return 0;
      final mean = sum / count;
      return math.sqrt(math.max(0, (sum2 / count) - (mean * mean)));
    }

    var left = 0;
    while (left < image.width ~/ 7 && lineVarianceVertical(left) < 8) {
      left++;
    }

    var right = image.width - 1;
    while (right > image.width * 6 ~/ 7 && lineVarianceVertical(right) < 8) {
      right--;
    }

    var top = 0;
    while (top < image.height ~/ 7 && lineVarianceHorizontal(top) < 8) {
      top++;
    }

    var bottom = image.height - 1;
    while (bottom > image.height * 6 ~/ 7 &&
        lineVarianceHorizontal(bottom) < 8) {
      bottom--;
    }

    final cropWidth = math.max(1, right - left);
    final cropHeight = math.max(1, bottom - top);
    if (cropWidth < image.width * 0.55 || cropHeight < image.height * 0.55) {
      return image;
    }

    return img.copyCrop(
      image,
      x: left,
      y: top,
      width: cropWidth,
      height: cropHeight,
    );
  }

  img.Image _enhanceForOcr(img.Image image) {
    var out = img.adjustColor(
      image,
      contrast: 1.16,
      saturation: 0.90,
      brightness: 1.01,
    );
    out = img.gaussianBlur(out, radius: 1);
    out = img.adjustColor(out, contrast: 1.12);
    return out;
  }

  List<double> _smooth(List<double> values, {required int radius}) {
    final out = List<double>.filled(values.length, 0);
    for (var i = 0; i < values.length; i++) {
      var total = 0.0;
      var count = 0;
      final start = math.max(0, i - radius);
      final end = math.min(values.length - 1, i + radius);
      for (var j = start; j <= end; j++) {
        total += values[j];
        count += 1;
      }
      out[i] = count == 0 ? 0 : total / count;
    }
    return out;
  }

  int _findPeak(
    List<double> values, {
    required int start,
    required int end,
    required double fallback,
  }) {
    var bestIndex = fallback.round();
    var bestScore = 0.0;
    for (var i = start; i < end; i++) {
      if (values[i] > bestScore) {
        bestScore = values[i];
        bestIndex = i;
      }
    }
    return bestIndex;
  }
}

class DocumentFrameAnalysis {
  const DocumentFrameAnalysis({
    required this.message,
    required this.readyForAutoCapture,
    this.rect,
  });

  final String message;
  final bool readyForAutoCapture;
  final DocumentRect? rect;
}

class DocumentRect {
  const DocumentRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  factory DocumentRect.fromPixels({
    required double left,
    required double top,
    required double right,
    required double bottom,
    required double frameWidth,
    required double frameHeight,
  }) {
    return DocumentRect(
      left: left / frameWidth,
      top: top / frameHeight,
      right: right / frameWidth,
      bottom: bottom / frameHeight,
    );
  }

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get areaRatio => width * height;
  double get aspectRatio => height == 0 ? 0 : width / height;

  double get centerDistanceFromFrameCenter {
    final cx = (left + right) / 2;
    final cy = (top + bottom) / 2;
    final dx = (cx - 0.5).abs();
    final dy = (cy - 0.5).abs();
    return math.sqrt((dx * dx) + (dy * dy));
  }

  double distanceFrom(DocumentRect other) {
    final dx = ((left + right) / 2) - ((other.left + other.right) / 2);
    final dy = ((top + bottom) / 2) - ((other.top + other.bottom) / 2);
    final dw = width - other.width;
    final dh = height - other.height;
    return math.sqrt((dx * dx) + (dy * dy) + (dw * dw) + (dh * dh));
  }

  PixelDocumentRect scaleTo({
    required double sourceWidth,
    required double sourceHeight,
  }) {
    return PixelDocumentRect(
      left: left * sourceWidth,
      top: top * sourceHeight,
      right: right * sourceWidth,
      bottom: bottom * sourceHeight,
    );
  }
}

class PixelDocumentRect {
  const PixelDocumentRect({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;

  PixelDocumentRect inflatePercent(double percent) {
    final dx = width * percent;
    final dy = height * percent;
    return PixelDocumentRect(
      left: math.max(0, left - dx),
      top: math.max(0, top - dy),
      right: right + dx,
      bottom: bottom + dy,
    );
  }
}

class _RectMetrics {
  const _RectMetrics({
    required this.brightness,
    required this.sharpness,
    required this.highlightRatio,
    required this.contrast,
    required this.borderStrength,
  });

  final double brightness;
  final double sharpness;
  final double highlightRatio;
  final double contrast;
  final double borderStrength;
}

class _OutsideMetrics {
  const _OutsideMetrics({
    required this.brightness,
  });

  final double brightness;
}
