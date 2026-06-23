# Guardianes4T Web/PWA

Esta version Web/PWA se agrego aparte para distribuir Guardianes4T por Safari en iPhone sin tocar el flujo actual de Android o iOS nativo.

## Que se agrego

- Ruta de captura separada para Web:
  - `lib/features/capture/scan_ine_screen_web.dart`
  - `lib/features/capture/scan_ine_screen_mobile.dart`
  - `lib/features/capture/scan_ine_screen.dart`
- OCR web en navegador con `Tesseract.js`
- Parser web para texto OCR:
  - `lib/services/web_ocr_parser.dart`
- Persistencia web compatible con la logica local:
  - `lib/data/local/db_api.dart`
  - `lib/data/local/db_api_web.dart`
- Ajustes PWA para Safari:
  - `web/index.html`
  - `web/manifest.json`
- Motor OCR web empaquetado localmente:
  - `web/ocr/tesseract.min.js`
  - `web/ocr/worker.min.js`
  - `web/ocr/tesseract-core*.wasm*`
  - `web/ocr/spa.traineddata.gz`

## Build web

Ejecutar dentro de `guardianes4t`:

```bash
flutter pub get
flutter build web
```

El resultado queda en:

```text
build/web
```

## Despliegue

Sube el contenido de `build/web` a cualquier hosting estatico HTTPS.

Opciones comunes:

- Hostinger
- Netlify
- Vercel
- Cloudflare Pages
- Nginx en tu VPS

## Requisito para Safari en iPhone

- El sitio debe abrir por `https://`
- Debe cargar `manifest.json`
- Debe conservar los archivos de `icons/`

## Instalar en iPhone con Safari

1. Abre la URL web de Guardianes4T en Safari.
2. Toca el boton de compartir.
3. Elige `Anadir a pantalla de inicio`.
4. Confirma el nombre `Guardianes4T`.
5. La app quedara instalada como acceso directo PWA.

## Nota sobre OCR web

En Web la lectura OCR usa `Tesseract.js` empaquetado dentro de la propia PWA para evitar depender de CDN externas. El flujo OCR sigue ocurriendo en el navegador y luego normaliza los datos antes de entrar al flujo existente de revision OCR y registro.

## Nota sobre offline

- La PWA puede abrir con cache local si ya fue cargada e instalada previamente.
- Los registros siguen usando la base local web existente para trabajo sin conexion.
- El OCR web ahora usa archivos locales del proyecto para no requerir descarga externa del motor OCR.

## Nota sobre Android/iOS

La ruta movil existente no se elimina:

- Android/iOS siguen usando `scan_ine_screen_mobile.dart`
- Web usa `scan_ine_screen_web.dart`

Esto evita mezclar la implementacion web con la compilacion movil actual.
