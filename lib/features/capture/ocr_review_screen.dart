import 'package:flutter/material.dart';

import '../../app/routes.dart';
import '../../services/ocr_validation_service.dart';

class OcrReviewScreen extends StatelessWidget {
  const OcrReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final args =
        (ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?) ??
            {};

    final processingMode = (args['processingMode'] ?? 'ocr_only').toString();

    final raw = <String, String>{
      'imagePath': (args['imagePath'] ?? '').toString(),
      'rawText': (args['rawText'] ?? '').toString(),
      'claveElectoral': (args['claveElectoral'] ?? '').toString(),
      'sexo': (args['sexo'] ?? '').toString(),
      'nombre': (args['nombre'] ?? '').toString(),
      'apellidoPaterno': (args['apellidoPaterno'] ?? '').toString(),
      'apellidoMaterno': (args['apellidoMaterno'] ?? '').toString(),
      'direccion': (args['direccion'] ?? '').toString(),
      'codigoPostal': (args['codigoPostal'] ?? '').toString(),
      'vigencia': (args['vigencia'] ?? '').toString(),
      'seccionElectoral': (args['seccionElectoral'] ?? '').toString(),
      'fechaNacimiento': (args['fechaNacimiento'] ?? '').toString(),
      'curp': (args['curp'] ?? '').toString(),
      'estado': (args['estado'] ?? '').toString(),
      'municipio': (args['municipio'] ?? '').toString(),
    };

    final validation = OcrValidationService().validate(raw);
    final data = validation.normalizedData;
    final warnings = validation.warnings;

    final fields = [
      _FieldItem('Clave de Elector', 'claveElectoral'),
      _FieldItem('Sexo', 'sexo'),
      _FieldItem('Nombre', 'nombre'),
      _FieldItem('Apellido Paterno', 'apellidoPaterno'),
      _FieldItem('Apellido Materno', 'apellidoMaterno'),
      _FieldItem('Direccion', 'direccion'),
      _FieldItem('Codigo Postal', 'codigoPostal'),
      _FieldItem('Estado', 'estado'),
      _FieldItem('Municipio', 'municipio'),
      _FieldItem('Vigencia', 'vigencia'),
      _FieldItem('SECCION', 'seccionElectoral'),
      _FieldItem('Fecha de Nacimiento', 'fechaNacimiento'),
      _FieldItem('CURP', 'curp'),
    ];

    const primary = Color(0xFF7A0C0C);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        title: const Text(
          'Revision OCR',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              warnings.isEmpty
                  ? 'Lectura completa. Puedes continuar.'
                  : 'Solo se muestran avisos cuando un dato no fue detectado.',
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: fields.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, index) {
                final item = fields[index];
                final value = (data[item.key] ?? '').trim();
                final warning = warnings[item.key];
                final hasWarning = warning != null;

                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFFE5E7EB),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        value.isEmpty ? 'No detectado' : value,
                        style: const TextStyle(fontSize: 16),
                      ),
                      if (hasWarning) ...[
                        const SizedBox(height: 6),
                        Text(
                          warning,
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pushNamed(
                          context,
                          AppRoutes.promotedForm,
                          arguments: {
                            ...data,
                            'processingMode': processingMode,
                          },
                        );
                      },
                      child: const Text('Continuar al formulario'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Volver a capturar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldItem {
  final String label;
  final String key;

  _FieldItem(this.label, this.key);
}
