import Flutter
import CoreImage
import UIKit
import Vision
import VisionKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var iosNativeIneScanner: IosNativeIneScanner?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      iosNativeIneScanner = IosNativeIneScanner(
        messenger: controller.binaryMessenger,
        presenter: controller
      )
    }

    return didFinish
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

final class IosNativeIneScanner: NSObject, VNDocumentCameraViewControllerDelegate {
  private static let channelName = "guardianes4t/ios_native_ine_scanner"

  private let channel: FlutterMethodChannel
  private weak var presenter: UIViewController?
  private let ciContext = CIContext()

  private var pendingResult: FlutterResult?
  private var documentCamera: VNDocumentCameraViewController?

  init(messenger: FlutterBinaryMessenger, presenter: UIViewController?) {
    self.channel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    self.presenter = presenter
    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "scanIne":
      startScan(result: result)
    case "processCapturedIne":
      processCapturedIne(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func processCapturedIne(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(
        FlutterError(
          code: "bad_args",
          message: "No se recibieron argumentos validos.",
          details: nil
        )
      )
      return
    }

    let imagePath = (args["imagePath"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !imagePath.isEmpty else {
      result(
        FlutterError(
          code: "missing_path",
          message: "No se recibio la ruta de la imagen.",
          details: nil
        )
      )
      return
    }

    guard let image = UIImage(contentsOfFile: imagePath) else {
      result(
        FlutterError(
          code: "image_not_found",
          message: "No se pudo abrir la imagen capturada.",
          details: nil
        )
      )
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let preparedImage = self.prepareBestDocumentImage(from: image)
      let bestText = self.recognizeBestText(from: preparedImage)
      let structuredData = self.recognizeStructuredIneFields(from: preparedImage)
      let finalImagePath = (try? self.saveImageToTemp(preparedImage)) ?? imagePath

      DispatchQueue.main.async {
        result([
          "imagePath": finalImagePath,
          "rawText": bestText,
          "source": "ios_vision_still_image",
          "structuredData": structuredData
        ])
      }
    }
  }

  private func startScan(result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(
        FlutterError(
          code: "busy",
          message: "Ya hay un escaneo nativo en curso.",
          details: nil
        )
      )
      return
    }

    guard VNDocumentCameraViewController.isSupported else {
      result(
        FlutterError(
          code: "not_supported",
          message: "VisionKit no esta disponible en este dispositivo.",
          details: nil
        )
      )
      return
    }

    guard let presenter = topViewController() else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "No se encontro una vista para abrir el escaner.",
          details: nil
        )
      )
      return
    }

    guard presenter.viewIfLoaded?.window != nil else {
      result(
        FlutterError(
          code: "presenter_not_ready",
          message: "La vista aun no esta lista para abrir el escaner.",
          details: nil
        )
      )
      return
    }

    if presenter.presentedViewController != nil {
      result(
        FlutterError(
          code: "presenter_busy",
          message: "Ya existe otra vista presentada en este momento.",
          details: nil
        )
      )
      return
    }

    pendingResult = result

    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    documentCamera = scanner
    DispatchQueue.main.async {
      presenter.present(scanner, animated: true)
    }
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    controller.dismiss(animated: true) { [weak self] in
      self?.finishWithError(
        FlutterError(
          code: "cancelled",
          message: "El usuario cancelo el escaneo.",
          details: nil
        )
      )
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFailWithError error: Error
  ) {
    controller.dismiss(animated: true) { [weak self] in
      self?.finishWithError(
        FlutterError(
          code: "scan_failed",
          message: error.localizedDescription,
          details: nil
        )
      )
    }
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    let bestImage = bestPageImage(from: scan)

    controller.dismiss(animated: true) { [weak self] in
      guard let self else { return }
      guard let image = bestImage else {
        self.finishWithError(
          FlutterError(
            code: "no_image",
            message: "No se pudo obtener la imagen escaneada.",
            details: nil
          )
        )
        return
      }

      DispatchQueue.global(qos: .userInitiated).async {
        self.process(image: image)
      }
    }
  }

  private func process(image: UIImage) {
    do {
      let preparedImage = prepareBestDocumentImage(from: image)
      let imagePath = try saveImageToTemp(preparedImage)
      let bestText = recognizeBestText(from: preparedImage)
      let structuredData = recognizeStructuredIneFields(from: preparedImage)

      DispatchQueue.main.async { [weak self] in
        self?.finishWithSuccess([
          "imagePath": imagePath,
          "rawText": bestText,
          "source": "ios_visionkit_native",
          "structuredData": structuredData
        ])
      }
    } catch {
      DispatchQueue.main.async { [weak self] in
        self?.finishWithError(
          FlutterError(
            code: "process_failed",
            message: error.localizedDescription,
            details: nil
          )
        )
      }
    }
  }

  private func bestPageImage(from scan: VNDocumentCameraScan) -> UIImage? {
    guard scan.pageCount > 0 else { return nil }

    var bestImage: UIImage?
    var bestScore = -Double.infinity

    for index in 0..<scan.pageCount {
      let image = scan.imageOfPage(at: index)
      let score = scoreScannedPage(image)
      if score > bestScore {
        bestScore = score
        bestImage = image
      }
    }

    return bestImage
  }

  private func scoreScannedPage(_ image: UIImage) -> Double {
    let width = Double(image.size.width)
    let height = Double(image.size.height)
    guard width > 0, height > 0 else { return 0 }

    let ratio = max(width, height) / min(width, height)
    let ineRatioTarget = 1.58
    let ratioPenalty = abs(ratio - ineRatioTarget) * 120
    let resolutionBonus = min(width * height / 15000, 180)
    let landscapeBonus = width > height ? 40 : 0

    return resolutionBonus + Double(landscapeBonus) - ratioPenalty
  }

  private func recognizeBestText(from image: UIImage) -> String {
    let preparedImage = prepareBestDocumentImage(from: image)
    let variants = imageVariants(from: preparedImage)
    var bestText = ""
    var bestScore = -Double.infinity
    var collectedTexts: [(String, Double)] = []

    for variant in variants {
      let text = recognizeText(from: variant)
      let score = scoreRecognizedText(text)
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        collectedTexts.append((text, score))
      }
      if score > bestScore {
        bestScore = score
        bestText = text
      }
    }

    let mergedText = mergeRecognizedTexts(collectedTexts)
    let mergedScore = scoreRecognizedText(mergedText)
    return mergedScore >= bestScore ? mergedText : bestText
  }

  private func recognizeStructuredIneFields(from image: UIImage) -> [String: String] {
    let normalized = normalizedImage(image)
    let base = upscaleIfNeeded(normalized, minimumLongSide: 3200) ?? normalized

    let fieldRegions: [(String, CGRect, Double, Double, Double)] = [
      ("nombreBloque", CGRect(x: 0.31, y: 0.17, width: 0.34, height: 0.22), 1.82, -0.01, 1.34),
      ("direccion", CGRect(x: 0.31, y: 0.37, width: 0.42, height: 0.19), 1.76, -0.01, 1.26),
      ("claveElectoral", CGRect(x: 0.31, y: 0.53, width: 0.53, height: 0.08), 1.88, -0.02, 1.38),
      ("curp", CGRect(x: 0.31, y: 0.61, width: 0.43, height: 0.08), 1.90, -0.02, 1.40),
      ("fechaNacimiento", CGRect(x: 0.31, y: 0.71, width: 0.26, height: 0.08), 1.92, -0.02, 1.42),
      ("seccionElectoral", CGRect(x: 0.57, y: 0.69, width: 0.12, height: 0.09), 1.94, -0.02, 1.46),
      ("vigencia", CGRect(x: 0.67, y: 0.69, width: 0.17, height: 0.09), 1.88, -0.02, 1.38),
      ("sexo", CGRect(x: 0.79, y: 0.18, width: 0.12, height: 0.08), 1.78, -0.02, 1.18)
    ]

    var rawValues: [String: String] = [:]

    for (key, rect, contrast, brightness, sharpness) in fieldRegions {
      guard let cropped = cropNormalizedRegion(base, rect: rect) else { continue }
      let upscaled = upscaleIfNeeded(cropped, minimumLongSide: 2200) ?? cropped
      let enhanced = applyFilters(
        to: upscaled,
        saturation: 0.0,
        contrast: contrast,
        brightness: brightness,
        sharpness: sharpness,
        noiseReduction: 0.015
      ) ?? upscaled
      rawValues[key] = recognizeText(from: enhanced)
    }

    return normalizeStructuredIneFields(rawValues)
  }

  private func normalizeStructuredIneFields(_ fields: [String: String]) -> [String: String] {
    var structured: [String: String] = [:]

    let upperNameBlock = cleanedIneText(fields["nombreBloque"] ?? "").uppercased()
    let nameLines = upperNameBlock
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.contains("NOMBRE") && !$0.contains("SEXO") }

    if !nameLines.isEmpty {
      structured["apellidoPaterno"] = nameLines[safe: 0] ?? ""
      structured["apellidoMaterno"] = nameLines[safe: 1] ?? ""
      if nameLines.count >= 3 {
        structured["nombre"] = nameLines.dropFirst(2).joined(separator: " ")
      } else if let fallback = nameLines.last {
        structured["nombre"] = fallback
      }
    }

    structured["direccion"] = cleanedIneText(fields["direccion"] ?? "")
    structured["claveElectoral"] = sanitizeClaveOrCurp(fields["claveElectoral"] ?? "", expectedLength: 18)
    structured["curp"] = sanitizeClaveOrCurp(fields["curp"] ?? "", expectedLength: 18)
    structured["fechaNacimiento"] = sanitizeDate(fields["fechaNacimiento"] ?? "")
    structured["seccionElectoral"] = sanitizeDigits(fields["seccionElectoral"] ?? "", minLength: 3, maxLength: 4)
    structured["vigencia"] = sanitizeVigencia(fields["vigencia"] ?? "")
    structured["sexo"] = sanitizeSexo(fields["sexo"] ?? "")

    return structured.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func imageVariants(from image: UIImage) -> [UIImage] {
    let baseImage = normalizedImage(image)
    var variants: [UIImage] = [baseImage]

    if let upscaled = upscaleIfNeeded(baseImage, minimumLongSide: 3000) {
      variants.append(upscaled)
    }

    if let enhanced = applyFilters(
      to: baseImage,
      saturation: 0.0,
      contrast: 1.35,
      brightness: 0.03,
      sharpness: 0.55
    ) {
      variants.append(enhanced)
    }

    if let highContrast = applyFilters(
      to: baseImage,
      saturation: 0.0,
      contrast: 1.60,
      brightness: 0.01,
      sharpness: 0.85
    ) {
      variants.append(highContrast)
    }

    if let crisp = applyFilters(
      to: baseImage,
      saturation: 0.0,
      contrast: 1.78,
      brightness: -0.01,
      sharpness: 1.15
    ) {
      variants.append(crisp)
    }

    if let microCrisp = applyFilters(
      to: baseImage,
      saturation: 0.0,
      contrast: 1.92,
      brightness: -0.015,
      sharpness: 1.38
    ) {
      variants.append(microCrisp)
    }

    if let denoised = applyFilters(
      to: baseImage,
      saturation: 0.0,
      contrast: 1.48,
      brightness: 0.02,
      sharpness: 0.72,
      noiseReduction: 0.02
    ) {
      variants.append(denoised)
    }

    variants.append(contentsOf: documentRegionVariants(from: baseImage))

    return variants
  }

  private func documentRegionVariants(from image: UIImage) -> [UIImage] {
    let normalized = normalizedImage(image)
    let base = upscaleIfNeeded(normalized, minimumLongSide: 3000) ?? normalized
    var variants: [UIImage] = []

    let textHeavyRegions: [(CGRect, Double, Double, Double)] = [
      (CGRect(x: 0.31, y: 0.11, width: 0.63, height: 0.72), 1.36, 0.02, 0.96),
      (CGRect(x: 0.31, y: 0.18, width: 0.41, height: 0.26), 1.48, 0.01, 1.14),
      (CGRect(x: 0.30, y: 0.36, width: 0.52, height: 0.22), 1.56, 0.01, 1.18),
      (CGRect(x: 0.29, y: 0.52, width: 0.66, height: 0.22), 1.62, 0.00, 1.24),
      (CGRect(x: 0.54, y: 0.50, width: 0.41, height: 0.27), 1.66, -0.01, 1.28),
      (CGRect(x: 0.28, y: 0.58, width: 0.34, height: 0.18), 1.68, -0.01, 1.30),
      (CGRect(x: 0.58, y: 0.58, width: 0.26, height: 0.18), 1.72, -0.01, 1.32)
    ]

    for (region, contrast, brightness, sharpness) in textHeavyRegions {
      guard let cropped = cropNormalizedRegion(base, rect: region) else { continue }
      let upscaled = upscaleIfNeeded(cropped, minimumLongSide: 2800) ?? cropped
      variants.append(upscaled)
      if let enhanced = applyFilters(
        to: upscaled,
        saturation: 0.0,
        contrast: contrast,
        brightness: brightness,
        sharpness: sharpness
      ) {
        variants.append(enhanced)
      }
    }

    return variants
  }

  private func applyFilters(
    to image: UIImage,
    saturation: Double,
    contrast: Double,
    brightness: Double,
    sharpness: Double,
    noiseReduction: Double = 0.0
  ) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let ciImage = CIImage(cgImage: cgImage)
    let colorControls = CIFilter(name: "CIColorControls")
    colorControls?.setValue(ciImage, forKey: kCIInputImageKey)
    colorControls?.setValue(saturation, forKey: kCIInputSaturationKey)
    colorControls?.setValue(contrast, forKey: kCIInputContrastKey)
    colorControls?.setValue(brightness, forKey: kCIInputBrightnessKey)

    guard let adjusted = colorControls?.outputImage else { return nil }

    let denoisedImage: CIImage
    if noiseReduction > 0 {
      let noiseFilter = CIFilter(name: "CINoiseReduction")
      noiseFilter?.setValue(adjusted, forKey: kCIInputImageKey)
      noiseFilter?.setValue(noiseReduction, forKey: "inputNoiseLevel")
      noiseFilter?.setValue(0.40, forKey: "inputSharpness")
      denoisedImage = noiseFilter?.outputImage ?? adjusted
    } else {
      denoisedImage = adjusted
    }

    let sharpen = CIFilter(name: "CISharpenLuminance")
    sharpen?.setValue(denoisedImage, forKey: kCIInputImageKey)
    sharpen?.setValue(sharpness, forKey: kCIInputSharpnessKey)

    guard
      let output = sharpen?.outputImage,
      let outputCgImage = ciContext.createCGImage(output, from: output.extent)
    else {
      return nil
    }

    return UIImage(
      cgImage: outputCgImage,
      scale: image.scale,
      orientation: image.imageOrientation
    )
  }

  private func recognizeText(from image: UIImage) -> String {
    guard let cgImage = image.cgImage else { return "" }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.0035
    request.recognitionLanguages = ["es-MX", "es-ES", "en-US"]
    request.customWords = [
      "INSTITUTO",
      "NACIONAL",
      "ELECTORAL",
      "CREDENCIAL",
      "VOTAR",
      "CLAVE",
      "ELECTOR",
      "CURP",
      "DOMICILIO",
      "SECCION",
      "VIGENCIA",
      "NACIMIENTO",
      "REGISTRO",
      "EDGAR",
      "MAURICIO",
      "OSORIO",
      "SANCHEZ",
      "PRIV",
      "JARDIN",
      "LAGO",
      "MEXICO",
      "JARDINES",
      "ZUMPANGO",
      "MEX",
      "CLAVEDELECTOR",
      "FECHADENACIMIENTO",
      "ANODEREGISTRO",
      "CREDENCIALPARAVOTAR"
    ]

    if #available(iOS 16.0, *) {
      request.revision = VNRecognizeTextRequestRevision3
    } else if #available(iOS 15.0, *) {
      request.revision = VNRecognizeTextRequestRevision2
    }

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

    do {
      try handler.perform([request])
      let observations = request.results ?? []
      let lines = observations.compactMap { observation in
        observation.topCandidates(1).first?.string
      }
      return lines.joined(separator: "\n")
    } catch {
      return ""
    }
  }

  private func scoreRecognizedText(_ text: String) -> Double {
    let normalized = text.uppercased()
    var score = Double(text.count)

    let keywords = [
      "INSTITUTO NACIONAL ELECTORAL",
      "CREDENCIAL PARA VOTAR",
      "CLAVE DE ELECTOR",
      "CURP",
      "DOMICILIO",
      "NOMBRE",
      "SECCION",
      "VIGENCIA",
      "FECHA DE NACIMIENTO"
    ]

    for keyword in keywords where normalized.contains(keyword) {
      score += 250
    }

    if normalized.range(
      of: #"[A-Z]{6}[0-9OILSZBQ]{6}[0-9OILSZBQ]{2}[HMN][0-9OILSZBQ]{3,4}"#,
      options: .regularExpression
    ) != nil {
      score += 320
    }

    if normalized.range(
      of: #"[A-Z]{4}[0-9OILSZBQ]{6}[HMN][A-Z]{5}[A-Z0-9]{2}"#,
      options: .regularExpression
    ) != nil {
      score += 320
    }

    if normalized.range(
      of: #"[0-9]{2}/[0-9]{2}/[0-9]{4}"#,
      options: .regularExpression
    ) != nil {
      score += 160
    }

    if normalized.range(
      of: #"[0-9]{4}\s*-\s*[0-9]{4}"#,
      options: .regularExpression
    ) != nil {
      score += 140
    }

    return score
  }

  private func saveImageToTemp(_ image: UIImage) throws -> String {
    guard let data = image.jpegData(compressionQuality: 1.0) else {
      throw NSError(
        domain: "IosNativeIneScanner",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "No se pudo serializar la imagen."]
      )
    }

    let fileName = "ios_native_ine_\(UUID().uuidString).jpg"
    let fileUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
    try data.write(to: fileUrl, options: .atomic)
    return fileUrl.path
  }

  private func finishWithSuccess(_ payload: [String: Any]) {
    pendingResult?(payload)
    cleanup()
  }

  private func finishWithError(_ error: FlutterError) {
    pendingResult?(error)
    cleanup()
  }

  private func cleanup() {
    pendingResult = nil
    documentCamera = nil
  }

  private func topViewController() -> UIViewController? {
    let rootController =
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first(where: { $0.isKeyWindow })?
        .rootViewController ?? presenter

    return topViewController(from: rootController)
  }

  private func mergeRecognizedTexts(_ texts: [(String, Double)]) -> String {
    guard !texts.isEmpty else { return "" }

    let ordered = texts.sorted { $0.1 > $1.1 }
    var mergedLines: [String] = []
    var seen = Set<String>()

    for (text, _) in ordered {
      let lines = text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

      for line in lines {
        let key = line
          .uppercased()
          .replacingOccurrences(of: " ", with: "")
        if seen.contains(key) { continue }
        seen.insert(key)
        mergedLines.append(line)
      }
    }

    return mergedLines.joined(separator: "\n")
  }

  private func normalizedImage(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up else { return image }

    let renderer = UIGraphicsImageRenderer(size: image.size)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }

  private func upscaleIfNeeded(_ image: UIImage, minimumLongSide: CGFloat) -> UIImage? {
    let longSide = max(image.size.width, image.size.height)
    guard longSide > 0, longSide < minimumLongSide else { return nil }

    let scale = minimumLongSide / longSide
    let newSize = CGSize(
      width: image.size.width * scale,
      height: image.size.height * scale
    )

    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: newSize))
    }
  }

  private func prepareBestDocumentImage(from image: UIImage) -> UIImage {
    let normalized = normalizedImage(image)
    let corrected = detectAndCorrectDocument(in: normalized) ?? normalized
    let scaled = upscaleIfNeeded(corrected, minimumLongSide: 3200) ?? corrected

    if let enhanced = applyFilters(
      to: scaled,
      saturation: 0.0,
      contrast: 1.28,
      brightness: 0.01,
      sharpness: 1.02,
      noiseReduction: 0.008
    ) {
      return enhanced
    }

    return scaled
  }

  private func cropNormalizedRegion(_ image: UIImage, rect: CGRect) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let width = CGFloat(cgImage.width)
    let height = CGFloat(cgImage.height)
    let cropRect = CGRect(
      x: rect.origin.x * width,
      y: rect.origin.y * height,
      width: rect.size.width * width,
      height: rect.size.height * height
    ).integral

    guard
      cropRect.width > 0,
      cropRect.height > 0,
      cropRect.maxX <= width,
      cropRect.maxY <= height,
      let cropped = cgImage.cropping(to: cropRect)
    else {
      return nil
    }

    return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
  }

  private func detectAndCorrectDocument(in image: UIImage) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let request = VNDetectRectanglesRequest()
    request.maximumObservations = 3
    request.minimumAspectRatio = 1.3
    request.maximumAspectRatio = 1.9
    request.minimumConfidence = 0.65
    request.minimumSize = 0.25
    request.quadratureTolerance = 20

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

    do {
      try handler.perform([request])
      guard
        let observations = request.results as? [VNRectangleObservation],
        let best = observations.max(by: { scoreRectangle($0) < scoreRectangle($1) })
      else {
        return nil
      }

      return perspectiveCorrect(image: image, rectangle: best)
    } catch {
      return nil
    }
  }

  private func scoreRectangle(_ rectangle: VNRectangleObservation) -> CGFloat {
    let widthA = hypot(
      rectangle.topRight.x - rectangle.topLeft.x,
      rectangle.topRight.y - rectangle.topLeft.y
    )
    let widthB = hypot(
      rectangle.bottomRight.x - rectangle.bottomLeft.x,
      rectangle.bottomRight.y - rectangle.bottomLeft.y
    )
    let heightA = hypot(
      rectangle.topLeft.x - rectangle.bottomLeft.x,
      rectangle.topLeft.y - rectangle.bottomLeft.y
    )
    let heightB = hypot(
      rectangle.topRight.x - rectangle.bottomRight.x,
      rectangle.topRight.y - rectangle.bottomRight.y
    )

    let avgWidth = (widthA + widthB) / 2
    let avgHeight = (heightA + heightB) / 2
    let ratio = avgHeight == 0 ? 0 : avgWidth / avgHeight
    let ratioPenalty = abs(ratio - 1.58) * 2.5
    let footprint = avgWidth * avgHeight
    return footprint - ratioPenalty
  }

  private func perspectiveCorrect(
    image: UIImage,
    rectangle: VNRectangleObservation
  ) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let ciImage = CIImage(cgImage: cgImage)
    let width = ciImage.extent.width
    let height = ciImage.extent.height

    func point(_ normalized: CGPoint) -> CIVector {
      CIVector(
        x: normalized.x * width,
        y: (1 - normalized.y) * height
      )
    }

    guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
      return nil
    }

    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(point(rectangle.topLeft), forKey: "inputTopLeft")
    filter.setValue(point(rectangle.topRight), forKey: "inputTopRight")
    filter.setValue(point(rectangle.bottomLeft), forKey: "inputBottomLeft")
    filter.setValue(point(rectangle.bottomRight), forKey: "inputBottomRight")

    guard
      let output = filter.outputImage,
      let correctedCgImage = ciContext.createCGImage(output, from: output.extent)
    else {
      return nil
    }

    return UIImage(cgImage: correctedCgImage, scale: image.scale, orientation: .up)
  }

  private func cleanedIneText(_ value: String) -> String {
    var text = value
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")

    let labels = [
      "NOMBRE",
      "DOMICILIO",
      "CLAVE DE ELECTOR",
      "CLAVEDELECTOR",
      "CURP",
      "FECHA DE NACIMIENTO",
      "FECHADENACIMIENTO",
      "SECCION",
      "VIGENCIA",
      "SEXO",
      "AÑO DE REGISTRO",
      "ANO DE REGISTRO"
    ]

    for label in labels {
      text = text.replacingOccurrences(of: label, with: "", options: [.caseInsensitive])
    }

    text = text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func sanitizeClaveOrCurp(_ value: String, expectedLength: Int) -> String {
    var raw = cleanedIneText(value)
      .uppercased()
      .replacingOccurrences(of: "[^A-Z0-9]", with: "", options: .regularExpression)

    raw = raw
      .replacingOccurrences(of: "0", with: "O")
      .replacingOccurrences(of: "1", with: "I")
      .replacingOccurrences(of: "5", with: "S")
      .replacingOccurrences(of: "8", with: "B")

    if raw.count >= expectedLength {
      return String(raw.prefix(expectedLength))
    }
    return raw
  }

  private func sanitizeDigits(_ value: String, minLength: Int, maxLength: Int) -> String {
    let digits = cleanedIneText(value)
      .replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)

    guard digits.count >= minLength else { return digits }
    return String(digits.prefix(maxLength))
  }

  private func sanitizeDate(_ value: String) -> String {
    let digits = cleanedIneText(value)
      .replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)

    guard digits.count >= 8 else { return cleanedIneText(value) }
    return "\(digits.prefix(2))/\(digits.dropFirst(2).prefix(2))/\(digits.dropFirst(4).prefix(4))"
  }

  private func sanitizeVigencia(_ value: String) -> String {
    let digits = cleanedIneText(value)
      .replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)

    guard digits.count >= 8 else { return cleanedIneText(value) }
    return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(4))"
  }

  private func sanitizeSexo(_ value: String) -> String {
    let raw = cleanedIneText(value).uppercased()
    if raw.contains("H") { return "H" }
    if raw.contains("M") { return "M" }
    return ""
  }

  private func topViewController(from base: UIViewController?) -> UIViewController? {
    guard let base else { return nil }
    if let navigation = base as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = base.presentedViewController {
      return topViewController(from: presented)
    }
    return base
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else { return nil }
    return self[index]
  }
}
