import 'package:guardianes4t/features/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Login screen renders expected copy', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: LoginScreen(),
      ),
    );

    expect(find.text('Guardianes4T'), findsOneWidget);
    expect(find.text('Entrar al sistema'), findsOneWidget);
  });
}
