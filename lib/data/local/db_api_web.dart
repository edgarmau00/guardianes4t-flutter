import 'dart:convert';
import 'dart:html' as html;

enum ConflictAlgorithm { replace }

typedef OnDatabaseVersionChangeFn = Future<void> Function(
  Database db,
  int version,
);

typedef OnDatabaseUpgradeFn = Future<void> Function(
  Database db,
  int oldVersion,
  int newVersion,
);

class Database {
  Database(this.storageKey, this.version, Map<String, List<Map<String, dynamic>>> initialTables)
      : _tables = initialTables;

  final String storageKey;
  final int version;
  final Map<String, List<Map<String, dynamic>>> _tables;

  Future<void> close() async {}

  Future<void> execute(String sql) async {}

  Future<List<Map<String, dynamic>>> query(
    String table, {
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
    int? limit,
  }) async {
    var rows = List<Map<String, dynamic>>.from(_tables[table] ?? const []);
    rows = rows.where((row) => _matchesWhere(row, where, whereArgs ?? const [])).toList();
    rows = _applyOrder(rows, orderBy);
    if (limit != null && rows.length > limit) {
      rows = rows.take(limit).toList();
    }
    if (columns != null && columns.isNotEmpty) {
      rows = rows
          .map(
            (row) => <String, dynamic>{
              for (final column in columns) column: row[column],
            },
          )
          .toList();
    }
    return rows.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<int> insert(
    String table,
    Map<String, dynamic> values, {
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    final rows = _tables.putIfAbsent(table, () => <Map<String, dynamic>>[]);
    final localId = (values['local_id'] ?? '').toString();
    final remoteId = (values['remote_id'] ?? '').toString();
    final existingIndex = rows.indexWhere((row) {
      final rowLocalId = (row['local_id'] ?? '').toString();
      final rowRemoteId = (row['remote_id'] ?? '').toString();
      if (localId.isNotEmpty && rowLocalId == localId) return true;
      if (remoteId.isNotEmpty && rowRemoteId == remoteId) return true;
      return false;
    });

    if (existingIndex >= 0 && conflictAlgorithm == ConflictAlgorithm.replace) {
      rows[existingIndex] = {
        ...rows[existingIndex],
        ...values,
      };
    } else if (existingIndex < 0) {
      rows.add(Map<String, dynamic>.from(values));
    }

    await _persist();
    return 1;
  }

  Future<int> update(
    String table,
    Map<String, dynamic> values, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = _tables[table] ?? <Map<String, dynamic>>[];
    var updated = 0;
    for (var i = 0; i < rows.length; i++) {
      if (_matchesWhere(rows[i], where, whereArgs ?? const [])) {
        rows[i] = {
          ...rows[i],
          ...values,
        };
        updated++;
      }
    }
    if (updated > 0) {
      await _persist();
    }
    return updated;
  }

  Future<int> delete(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final rows = _tables[table] ?? <Map<String, dynamic>>[];
    final originalLength = rows.length;
    rows.removeWhere(
      (row) => _matchesWhere(row, where, whereArgs ?? const []),
    );
    final deleted = originalLength - rows.length;
    if (deleted > 0) {
      await _persist();
    }
    return deleted;
  }

  Future<List<Map<String, dynamic>>> rawQuery(String sql) async {
    final match = RegExp(
      r'SELECT COUNT\(\*\) as (\w+) FROM (\w+)',
      caseSensitive: false,
    ).firstMatch(sql.trim());
    if (match == null) {
      return const [];
    }

    final alias = match.group(1) ?? 'total';
    final table = match.group(2) ?? '';
    return [
      {alias: (_tables[table] ?? const []).length},
    ];
  }

  Future<void> clear() async {
    _tables.clear();
    await _persist();
  }

  Future<void> _persist() async {
    html.window.localStorage[storageKey] = jsonEncode({
      'version': version,
      'tables': _tables,
    });
  }
}

Database openWebDatabase(
  String storageKey, {
  required int version,
  required Map<String, List<Map<String, dynamic>>> initialTables,
}) {
  final raw = html.window.localStorage[storageKey];
  if (raw == null || raw.trim().isEmpty) {
    return Database(storageKey, version, initialTables);
  }

  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final decodedVersion = decoded['version'] as int? ?? 0;
    final tablesRaw = decoded['tables'] as Map<String, dynamic>? ?? const {};
    final tables = <String, List<Map<String, dynamic>>>{};

    for (final entry in tablesRaw.entries) {
      final rows = (entry.value as List<dynamic>? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      tables[entry.key] = rows;
    }

    final merged = <String, List<Map<String, dynamic>>>{
      ...initialTables,
      ...tables,
    };

    return Database(storageKey, decodedVersion > version ? decodedVersion : version, merged);
  } catch (_) {
    html.window.localStorage.remove(storageKey);
    return Database(storageKey, version, initialTables);
  }
}

void deleteWebDatabase(String storageKey) {
  html.window.localStorage.remove(storageKey);
}

Future<void> deleteDatabase(String path) async {
  deleteWebDatabase(path);
}

Future<String> getDatabasesPath() async {
  return 'guardianes4t_web';
}

Future<Database> openDatabase(
  String path, {
  String? password,
  int? version,
  OnDatabaseVersionChangeFn? onCreate,
  OnDatabaseUpgradeFn? onUpgrade,
}) async {
  final db = openWebDatabase(
    path,
    version: version ?? 1,
    initialTables: <String, List<Map<String, dynamic>>>{},
  );

  if (onCreate != null) {
    await onCreate(db, version ?? 1);
  }

  return db;
}

List<Map<String, dynamic>> _applyOrder(
  List<Map<String, dynamic>> rows,
  String? orderBy,
) {
  if (orderBy == null || orderBy.trim().isEmpty) {
    return rows;
  }

  final parts = orderBy.trim().split(RegExp(r'\s+'));
  final field = parts.first;
  final descending = parts.length > 1 && parts[1].toUpperCase() == 'DESC';

  rows.sort((a, b) {
    final left = a[field];
    final right = b[field];
    final result = _compareValues(left, right);
    return descending ? -result : result;
  });

  return rows;
}

int _compareValues(dynamic left, dynamic right) {
  if (left == null && right == null) return 0;
  if (left == null) return -1;
  if (right == null) return 1;

  final leftNum = num.tryParse(left.toString());
  final rightNum = num.tryParse(right.toString());
  if (leftNum != null && rightNum != null) {
    return leftNum.compareTo(rightNum);
  }

  return left.toString().compareTo(right.toString());
}

bool _matchesWhere(Map<String, dynamic> row, String? where, List<Object?> args) {
  if (where == null || where.trim().isEmpty) {
    return true;
  }

  final normalizedWhere = _stripOuterParentheses(where.trim());
  final orSegments = _splitTopLevel(normalizedWhere, 'OR');

  for (final orSegment in orSegments) {
    final andSegments = _splitTopLevel(orSegment, 'AND');
    var localOffset = 0;
    var matches = true;

    for (final condition in andSegments) {
      final placeholderCount = RegExp(r'\?').allMatches(condition).length;
      final conditionArgs = args
          .skip(localOffset)
          .take(placeholderCount)
          .toList();
      localOffset += placeholderCount;
      if (!_matchesCondition(
        row,
        _stripOuterParentheses(condition.trim()),
        conditionArgs,
      )) {
        matches = false;
        break;
      }
    }

    if (matches) {
      return true;
    }
  }

  return false;
}

bool _matchesCondition(
  Map<String, dynamic> row,
  String condition,
  List<Object?> args,
) {
  condition = _stripOuterParentheses(condition.trim());

  final upperMatch = RegExp(r'^UPPER\(([\w_]+)\)\s*=\s*\?$').firstMatch(condition);
  if (upperMatch != null) {
    final field = upperMatch.group(1)!;
    return (row[field] ?? '').toString().toUpperCase() ==
        (args.firstOrNull ?? '').toString().toUpperCase();
  }

  final lowerMatch = RegExp(r'^LOWER\(([\w_]+)\)\s*=\s*\?$').firstMatch(condition);
  if (lowerMatch != null) {
    final field = lowerMatch.group(1)!;
    return (row[field] ?? '').toString().toLowerCase() ==
        (args.firstOrNull ?? '').toString().toLowerCase();
  }

  final inMatch = RegExp(r'^([\w_]+)\s+IN\s+\((.+)\)$', caseSensitive: false).firstMatch(condition);
  if (inMatch != null) {
    final field = inMatch.group(1)!;
    final value = row[field];
    return args.any((arg) => _sameValue(value, arg));
  }

  final eqMatch = RegExp(r'^([\w_]+)\s*=\s*\?$').firstMatch(condition);
  if (eqMatch != null) {
    final field = eqMatch.group(1)!;
    return _sameValue(row[field], args.firstOrNull);
  }

  return false;
}

bool _sameValue(dynamic left, dynamic right) {
  final leftNum = num.tryParse((left ?? '').toString());
  final rightNum = num.tryParse((right ?? '').toString());
  if (leftNum != null && rightNum != null) {
    return leftNum == rightNum;
  }
  return (left ?? '').toString() == (right ?? '').toString();
}

List<String> _splitTopLevel(String expression, String operator) {
  final parts = <String>[];
  final buffer = StringBuffer();
  final upperOperator = operator.toUpperCase();
  var depth = 0;
  var index = 0;

  while (index < expression.length) {
    final char = expression[index];

    if (char == '(') {
      depth++;
      buffer.write(char);
      index++;
      continue;
    }

    if (char == ')') {
      depth = depth > 0 ? depth - 1 : 0;
      buffer.write(char);
      index++;
      continue;
    }

    if (depth == 0) {
      final remaining = expression.substring(index);
      final operatorMatch = RegExp(
        '^\\s+$upperOperator\\s+',
        caseSensitive: false,
      ).firstMatch(remaining);

      if (operatorMatch != null) {
        final part = buffer.toString().trim();
        if (part.isNotEmpty) {
          parts.add(part);
        }
        buffer.clear();
        index += operatorMatch.group(0)!.length;
        continue;
      }
    }

    buffer.write(char);
    index++;
  }

  final lastPart = buffer.toString().trim();
  if (lastPart.isNotEmpty) {
    parts.add(lastPart);
  }

  return parts.isEmpty ? [expression.trim()] : parts;
}

String _stripOuterParentheses(String value) {
  var result = value.trim();

  while (result.startsWith('(') && result.endsWith(')')) {
    var depth = 0;
    var wrapsWholeExpression = true;

    for (var i = 0; i < result.length; i++) {
      final char = result[i];
      if (char == '(') depth++;
      if (char == ')') depth--;

      if (depth == 0 && i < result.length - 1) {
        wrapsWholeExpression = false;
        break;
      }
    }

    if (!wrapsWholeExpression) {
      break;
    }

    result = result.substring(1, result.length - 1).trim();
  }

  return result;
}
