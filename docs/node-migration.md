# Migracion Flutter -> Node/PostgreSQL

## Estado actual

La app Flutter depende hoy de:

- `FirebaseAuth` para login, logout, reset de password y aprovisionamiento de lideres.
- `FirestoreService` para roles, lideres, promovidos y grupos de WhatsApp.
- `SyncService` para subir pendientes y bajar datos remotos.

## Backend creado

El nuevo backend vive en [backend](/c:/Users/sanch/Music/Guardianes4T/backend) y ya incluye:

- JWT para autenticacion
- PostgreSQL como fuente principal de datos
- rutas REST para auth, lideres, promovidos y grupos
- `GET /api/sync/bootstrap` para carga inicial y sincronizacion

## Reemplazos sugeridos en Flutter

- `AuthService.login` -> `POST /api/auth/login`
- `AuthService.logout` -> limpiar token local
- `AuthService.sendPasswordReset` -> endpoint propio pendiente
- `AuthService.provisionLeaderAccess` -> `POST /api/leaders`
- `FirestoreService.isCurrentUserAdmin` -> `GET /api/auth/me`
- `FirestoreService.fetchCurrentLeaderProfile` -> `GET /api/auth/me`
- `FirestoreService.fetchPromotedByCurrentCapturist` -> `GET /api/promoted`
- `FirestoreService.fetchLeadersByCurrentCapturist` -> `GET /api/leaders`
- `FirestoreService.fetchWhatsappGroups` -> `GET /api/whatsapp-groups`
- `SyncService.pull*` -> `GET /api/sync/bootstrap`
- `SyncService.syncPendingPromoted` -> `POST /api/promoted`
- `SyncService.syncPendingLeaders` -> `POST /api/leaders`
- `SyncService.syncPendingWhatsappGroups` -> `POST /api/whatsapp-groups`

## Orden recomendado

1. Crear `ApiSessionService` para guardar `accessToken` en `flutter_secure_storage`.
2. Crear `ApiClient` con header `Authorization: Bearer <token>`.
3. Reescribir `AuthService` para usar la API Node.
4. Reemplazar `FirestoreService` por `ApiSyncService`.
5. Retirar `firebase_core`, `firebase_auth`, `cloud_firestore` y reglas de Firestore.

## Nota importante

La app sigue funcionando con Firebase; esta entrega deja lista la base del backend nuevo, pero todavia no cambia el frontend para consumirlo.
