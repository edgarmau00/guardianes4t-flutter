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
    default:
      result(FlutterMethodNotImplemented)
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

    guard let presenter = topViewController(from: presenter) else {
      result(
        FlutterError(
          code: "no_presenter",
          message: "No se encontro una vista para abrir el escaner.",
          details: nil
        )
      )
      return
    }

    pendingResult = result

    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    documentCamera = scanner
    presenter.present(scanner, animated: true)
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
      let imagePath = try saveImageToTemp(image)
      let bestText = recognizeBestText(from: image)

      DispatchQueue.main.async { [weak self] in
        self?.finishWithSuccess([
          "imagePath": imagePath,
          "rawText": bestText,
          "source": "ios_visionkit_native"
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

    return resolutionBonus + landscapeBonus - ratioPenalty
  }

  private func recognizeBestText(from image: UIImage) -> String {
    let variants = imageVariants(from: image)
    var bestText = ""
    var bestScore = -Double.infinity

    for variant in variants {
      let text = recognizeText(from: variant)
      let score = scoreRecognizedText(text)
      if score > bestScore {
        bestScore = score
        bestText = text
      }
    }

    return bestText
  }

  private func imageVariants(from image: UIImage) -> [UIImage] {
    var variants: [UIImage] = [image]

    if let enhanced = applyFilters(
      to: image,
      saturation: 0.0,
      contrast: 1.35,
      brightness: 0.03,
      sharpness: 0.55
    ) {
      variants.append(enhanced)
    }

    if let highContrast = applyFilters(
      to: image,
      saturation: 0.0,
      contrast: 1.60,
      brightness: 0.01,
      sharpness: 0.85
    ) {
      variants.append(highContrast)
    }

    return variants
  }

  private func applyFilters(
    to image: UIImage,
    saturation: Double,
    contrast: Double,
    brightness: Double,
    sharpness: Double
  ) -> UIImage? {
    guard let cgImage = image.cgImage else { return nil }

    let ciImage = CIImage(cgImage: cgImage)
    let colorControls = CIFilter(name: "CIColorControls")
    colorControls?.setValue(ciImage, forKey: kCIInputImageKey)
    colorControls?.setValue(saturation, forKey: kCIInputSaturationKey)
    colorControls?.setValue(contrast, forKey: kCIInputContrastKey)
    colorControls?.setValue(brightness, forKey: kCIInputBrightnessKey)

    guard let adjusted = colorControls?.outputImage else { return nil }

    let sharpen = CIFilter(name: "CISharpenLuminance")
    sharpen?.setValue(adjusted, forKey: kCIInputImageKey)
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
    request.minimumTextHeight = 0.012
    request.recognitionLanguages = ["es-MX", "es-ES", "en-US"]

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

    return score
  }

  private func saveImageToTemp(_ image: UIImage) throws -> String {
    guard let data = image.jpegData(compressionQuality: 0.96) else {
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

  private func topViewController(from base: UIViewController?) -> UIViewController? {
    if let navigation = base as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = base as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = base?.presentedViewController {
      return topViewController(from: presented)
    }
    return base
  }
}
