import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/sync_service.dart';
import '../services/auth_service.dart';
import 'routes.dart';
import 'theme.dart';

class Guardianes4TApp extends StatefulWidget {
  const Guardianes4TApp({super.key});

  @override
  State<Guardianes4TApp> createState() => _Guardianes4TAppState();
}

class _Guardianes4TAppState extends State<Guardianes4TApp>
    with WidgetsBindingObserver {
  static const Duration _sessionTimeout = Duration(minutes: 5);

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AuthService _authService = AuthService();
  DateTime _lastActivityAt = DateTime.now();
  bool _sessionClosing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _closeSessionIfExpired();
      _markActivity();
    }
  }

  void _markActivity() {
    _lastActivityAt = DateTime.now();
  }

  Future<void> _closeSessionIfExpired() async {
    if (_sessionClosing) {
      return;
    }

    final currentUser = _authService.currentUser;
    final currentRoute =
        ModalRoute.of(_navigatorKey.currentContext ?? context)?.settings.name;
    if (currentUser == null || currentRoute == AppRoutes.login) {
      return;
    }

    final inactiveFor = DateTime.now().difference(_lastActivityAt);
    if (inactiveFor < _sessionTimeout) {
      return;
    }

    _sessionClosing = true;
    try {
      await _authService.logout();
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppRoutes.login,
        (route) => false,
      );
      final messenger = ScaffoldMessenger.maybeOf(_navigatorKey.currentContext!);
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Sesion cerrada por inactividad'),
        ),
      );
    } finally {
      _sessionClosing = false;
      _markActivity();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<SyncService>(
          create: (_) => SyncService()..startListening(),
        ),
      ],
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _markActivity(),
        onPointerMove: (_) => _markActivity(),
        child: MaterialApp(
          navigatorKey: _navigatorKey,
          debugShowCheckedModeBanner: false,
          title: 'Guardianes4T',
          theme: buildAppTheme(),
          initialRoute:
              _authService.currentUser == null ? AppRoutes.login : AppRoutes.dashboard,
          routes: AppRoutes.routes,
        ),
      ),
    );
  }
}
