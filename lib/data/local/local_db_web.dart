import 'db_api.dart';

class LocalDb {
  static final LocalDb instance = LocalDb._();
  LocalDb._();

  static const _storageKey = 'guardianes4t_web_db_v8';
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;

    _db = openWebDatabase(
      _storageKey,
      version: 8,
      initialTables: {
        'promoted_records': <Map<String, dynamic>>[],
        'leader_records': <Map<String, dynamic>>[],
        'whatsapp_groups': <Map<String, dynamic>>[],
      },
    );
    return _db!;
  }

  Future<void> reset() async {
    await _db?.clear();
    deleteWebDatabase(_storageKey);
    _db = null;
  }
}
