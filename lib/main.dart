import 'package:flutter/material.dart';

import 'app/app.dart';
import 'services/auth_service.dart';
import 'services/cp_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await CpService.load();
  await AuthService().initialize();

  runApp(const Guardianes4TApp());
}
