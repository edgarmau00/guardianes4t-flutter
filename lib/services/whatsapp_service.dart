import 'package:url_launcher/url_launcher.dart';

class WhatsappService {
  static Future<void> openChat({
    required String phone,
    required String name,
    required String section,
  }) async {
    final message = Uri.encodeComponent(
      'Hola $name, gracias por registrarte en la sección $section.',
    );
    final uri = Uri.parse('https://wa.me/52$phone?text=$message');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}