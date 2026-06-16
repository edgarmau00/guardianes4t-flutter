import 'package:flutter/material.dart';
import '../../app/routes.dart';
import '../../widgets/primary_button.dart';

class CaptureMenuScreen extends StatelessWidget {
  const CaptureMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guardianes4T')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            Container(
              height: 220,
              width: 220,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              alignment: Alignment.center,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    'Guardianes4T',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 34,
                      color: Color(0xFF7A0C0C),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            PrimaryButton(
              text: 'Registro con INE',
              onPressed: () => Navigator.pushNamed(context, AppRoutes.scanIne),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
