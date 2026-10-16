import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:ords_ba/Api_config/api_config.dart';
import 'package:ords_ba/Model/models.dart';

/// Thrown for any failed API call. [message] is safe to show to the user.
class ApiException implements Exception {
  final String message;
  final int? statusCode;
  const ApiException(this.message, [this.statusCode]);

  bool get isUnauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

class LoginResult {
  final String token;
  final AppUser user;
  const LoginResult(this.token, this.user);
}

/// Every network call of the BA module lives here.
class Repository {
  Repository({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /* ----------------------------- helpers ----------------------------- */

  Map<String, String> _headers({String? token, bool json = true}) => {
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  dynamic _tryDecode(String body) {
    if (body.trim().isEmpty) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  String? _messageOf(dynamic data) {
    if (data is Map) {
      for (final k in ['message', 'error', 'msg', 'detail', 'error_message']) {
        final v = data[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      // ORDS error shape: {"code": "...", "message": "..."} handled above.
      final nested = data['data'];
      if (nested is Map) return _messageOf(nested);
    }
    if (data is String && data.trim().isNotEmpty) return data;
    return null;
  }

  /// Sends a request, decodes the JSON and converts every kind of failure
  /// (HTTP error, `success:false`, no internet, timeout) into [ApiException].
  Future<dynamic> _send(Future<http.Response> Function() call) async {
    http.Response res;
    try {
      res = await call().timeout(ApiConfig.timeout);
    } on SocketException {
      throw const ApiException('No internet connection. Please try again.');
    } on TimeoutException {
      throw const ApiException('Server took too long to respond. Try again.');
    } on http.ClientException {
      throw const ApiException('Could not reach the server. Try again.');
    }

    final data = _tryDecode(utf8.decode(res.bodyBytes));

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final fallback = switch (res.statusCode) {
        401 => 'Session expired. Please login again.',
        403 => 'You are not allowed to do this.',
        404 => 'Service not found (404).',
        _ => 'Request failed (${res.statusCode}).',
      };
      throw ApiException(_messageOf(data) ?? fallback, res.statusCode);
    }

    // Some ORDS handlers answer 200 with a failure flag in the body.
    if (data is Map) {
      final success = data['success'];
      final status = data['status']?.toString().toLowerCase();
      final failed = success == false ||
          success?.toString().toLowerCase() == 'false' ||
          status == 'error' ||
          status == 'fail' ||
          status == 'failed';
      if (failed) {
        throw ApiException(
            _messageOf(data) ?? 'Request failed.', res.statusCode);
      }
    }
    return data;
  }

  /// Unwraps common response wrappers (`data`, `user`, `profile`, `result`),
  /// descending until the innermost user-like map is reached.
  Map<String, dynamic>? _findMap(dynamic data, [int depth = 0]) {
    if (data is! Map) return null;
    if (depth < 3) {
      for (final k in ['user', 'profile', 'data', 'result']) {
        final v = data[k];
        if (v is Map) return _findMap(v, depth + 1);
      }
    }
    return Map<String, dynamic>.from(data);
  }

  String? _findToken(dynamic data) {
    if (data is Map) {
      for (final k in [
        'token',
        'access_token',
        'auth_token',
        'session_token',
        'bearer_token',
      ]) {
        final v = data[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString();
      }
      for (final k in ['data', 'result', 'user']) {
        final t = _findToken(data[k]);
        if (t != null) return t;
      }
    }
    return null;
  }

  /// Reads an ORDS collection (`items` + `next.$ref` paging) fully.
  Future<List<Map<String, dynamic>>> _getAll(String firstUrl,
      {String? token}) async {
    final out = <Map<String, dynamic>>[];
    final seenUrls = <String>{};
    String? url = firstUrl;
    var guard = 0;

    while (url != null && seenUrls.add(url) && guard++ < 100) {
      final data = await _send(
          () => _client.get(Uri.parse(url!), headers: _headers(token: token, json: false)));

      List? items;
      if (data is List) {
        items = data;
      } else if (data is Map) {
        items = (data['items'] ?? data['data'] ?? data['results']) as List?;
      }
      for (final e in items ?? const []) {
        if (e is Map) out.add(Map<String, dynamic>.from(e));
      }

      String? next;
      if (data is Map) {
        final n = data['next'];
        if (n is Map && n[r'$ref'] != null) next = n[r'$ref'].toString();
        if (data['hasMore'] == false) next = null;
      }
      if ((items ?? const []).isEmpty) next = null;
      url = next;
    }
    return out;
  }

  /* ------------------------------ locations ------------------------------ */

  

Future<List<MartLocation>> fetchLocations() async {
  final response = await http.get(
    Uri.parse('http://tapex.mezangrp.com/ords/hrms/ba-sales-v2/locations/list/'),
    headers: {
      'Accept': 'application/json',
    },
  );

  if (response.statusCode != 200) {
    throw ApiException(
      'Failed to load locations. HTTP ${response.statusCode}',
    );
  }

final Map<String, dynamic> data = jsonDecode(response.body);

if (data['success'] != true) {
  throw Exception(
    data['message']?.toString() ?? 'Failed to fetch locations',
  );
}

final List<dynamic> items = data['locations'] as List<dynamic>? ?? [];

return items.map((item) {
  return MartLocation.fromJson(
    Map<String, dynamic>.from(item as Map),
  );
}).toList();
}

  /* -------------------------------- auth -------------------------------- */

  Future<String> signup({
    required String fullName,
    required String email,
    required String cnic,
    required String password,
    required String confirmPassword,
    required int locationId,
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.signup),
          headers: _headers(),
          body: jsonEncode({
            'full_name': fullName,
            'email': email,
            'cnic': cnic,
            'password': password,
            'confirm_password': confirmPassword,
            'role': 'BA',
            'location_id': locationId,
          }),
        ));
    return _messageOf(data) ?? 'Account created. Please login.';
  }

  Future<LoginResult> login({
    required String email,
    required String password,
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.login),
          headers: _headers(),
          body: jsonEncode({'email': email, 'password': password}),
        ));

    final token = _findToken(data);
    if (token == null) {
      throw const ApiException('Login succeeded but no token was returned.');
    }
    final map = _findMap(data) ?? {};
    final user = AppUser.fromJson(map);
    return LoginResult(
      token,
      user.email.isEmpty ? user.mergeWith(AppUser(id: '', fullName: 'BA', email: email)) : user,
    );
  }

  Future<AppUser> fetchProfile(String token) async {
    final data = await _send(() => _client.get(
          Uri.parse(ApiConfig.profile),
          headers: _headers(token: token, json: false),
        ));
    final map = _findMap(data);
    if (map == null) throw const ApiException('Could not read profile.');
    return AppUser.fromJson(map);
  }

  /* ----------------------------- attendance ----------------------------- */

  Future<String> attendanceIn({
    required String token,
    required double latitude,
    required double longitude,
       required int locationId,
  }) =>
      _attendance(ApiConfig.attendanceIn, token, latitude, longitude,locationId,
          'Attendance IN marked.');

  Future<String> attendanceOut({
    required String token,
    required double latitude,
    required double longitude,
       required int locationId,
  }) =>
      _attendance(ApiConfig.attendanceOut, token, latitude, longitude,locationId,
          'Attendance OUT marked.');

  Future<String> _attendance(String url, String token, double lat, double lng,int locationId,
      String fallback) async {
    final data = await _send(() => _client.post(
          Uri.parse(url),
          headers: _headers(token: token),
          body: jsonEncode({
            'latitude': lat,
            'longitude': lng,
            'location_id': locationId,
          }),
        ));
    return _messageOf(data) ?? fallback;
  }

  /* -------------------------------- sales -------------------------------- */

  /// Active SKUs only (inactive ones are skipped).
  Future<List<Sku>> fetchSkus() async {
    final rows = await _getAll(ApiConfig.skuList);
    final seen = <int>{};
    final out = <Sku>[];
    for (final r in rows) {
      if (!Sku.isActive(r)) continue;
      final s = Sku.fromJson(r);
      if (s.skuId == 0 || !seen.add(s.skuId)) continue;
      out.add(s);
    }
    out.sort((a, b) {
      final g = a.group.toLowerCase().compareTo(b.group.toLowerCase());
      return g != 0 ? g : a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
    });
    return out;
  }

  Future<String> enterSales({
    required String token,
    required int locationId,
    required String saleDate, // yyyy-MM-dd
    required Map<int, int> quantities, // sku_id -> qty
  }) async {
    final data = await _send(() => _client.post(
          Uri.parse(ApiConfig.enterSales),
          headers: _headers(token: token),
          body: jsonEncode({
            'location_id': locationId,
            'sale_date': saleDate,
            'items': [
              for (final e in quantities.entries)
                {'sku_id': e.key, 'quantity': e.value},
            ],
          }),
        ));
    return _messageOf(data) ?? 'Sales saved.';
  }
}// import 'dart:async';
// import 'dart:convert';
// import 'dart:io';

// import 'package:http/http.dart' as http;
// import 'package:ords_ba/Api_config/api_config.dart';
// import 'package:ords_ba/Model/models.dart';

// /// Thrown for any failed API call. [message] is safe to show to the user.
// class ApiException implements Exception {
//   final String message;
//   final int? statusCode;
//   const ApiException(this.message, [this.statusCode]);

//   bool get isUnauthorized => statusCode == 401 || statusCode == 403;

//   @override
//   String toString() => message;
// }

// class LoginResult {
//   final String token;
//   final AppUser user;
//   const LoginResult(this.token, this.user);
// }

// /// Every network call of the BA module lives here.
// class Repository {
//   Repository({http.Client? client}) : _client = client ?? http.Client();
//   final http.Client _client;

//   /* ----------------------------- helpers ----------------------------- */

//   Map<String, String> _headers({String? token, bool json = true}) => {
//         'Accept': 'application/json',
//         if (json) 'Content-Type': 'application/json',
//         if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
//       };

//   dynamic _tryDecode(String body) {
//     if (body.trim().isEmpty) return null;
//     try {
//       return jsonDecode(body);
//     } catch (_) {
//       return null;
//     }
//   }

//   String? _messageOf(dynamic data) {
//     if (data is Map) {
//       for (final k in ['message', 'error', 'msg', 'detail', 'error_message']) {
//         final v = data[k];
//         if (v != null && v.toString().trim().isNotEmpty) return v.toString();
//       }
//       // ORDS error shape: {"code": "...", "message": "..."} handled above.
//       final nested = data['data'];
//       if (nested is Map) return _messageOf(nested);
//     }
//     if (data is String && data.trim().isNotEmpty) return data;
//     return null;
//   }

//   /// Sends a request, decodes the JSON and converts every kind of failure
//   /// (HTTP error, `success:false`, no internet, timeout) into [ApiException].
//   Future<dynamic> _send(Future<http.Response> Function() call) async {
//     http.Response res;
//     try {
//       res = await call().timeout(ApiConfig.timeout);
//     } on SocketException {
//       throw const ApiException('No internet connection. Please try again.');
//     } on TimeoutException {
//       throw const ApiException('Server took too long to respond. Try again.');
//     } on http.ClientException {
//       throw const ApiException('Could not reach the server. Try again.');
//     }

//     final data = _tryDecode(utf8.decode(res.bodyBytes));

//     if (res.statusCode < 200 || res.statusCode >= 300) {
//       final fallback = switch (res.statusCode) {
//         401 => 'Session expired. Please login again.',
//         403 => 'You are not allowed to do this.',
//         404 => 'Service not found (404).',
//         _ => 'Request failed (${res.statusCode}).',
//       };
//       throw ApiException(_messageOf(data) ?? fallback, res.statusCode);
//     }

//     // Some ORDS handlers answer 200 with a failure flag in the body.
//     if (data is Map) {
//       final success = data['success'];
//       final status = data['status']?.toString().toLowerCase();
//       final failed = success == false ||
//           success?.toString().toLowerCase() == 'false' ||
//           status == 'error' ||
//           status == 'fail' ||
//           status == 'failed';
//       if (failed) {
//         throw ApiException(
//             _messageOf(data) ?? 'Request failed.', res.statusCode);
//       }
//     }
//     return data;
//   }

//   /// Unwraps common response wrappers (`data`, `user`, `profile`, `result`),
//   /// descending until the innermost user-like map is reached.
//   Map<String, dynamic>? _findMap(dynamic data, [int depth = 0]) {
//     if (data is! Map) return null;
//     if (depth < 3) {
//       for (final k in ['user', 'profile', 'data', 'result']) {
//         final v = data[k];
//         if (v is Map) return _findMap(v, depth + 1);
//       }
//     }
//     return Map<String, dynamic>.from(data);
//   }

//   String? _findToken(dynamic data) {
//     if (data is Map) {
//       for (final k in [
//         'token',
//         'access_token',
//         'auth_token',
//         'session_token',
//         'bearer_token',
//       ]) {
//         final v = data[k];
//         if (v != null && v.toString().trim().isNotEmpty) return v.toString();
//       }
//       for (final k in ['data', 'result', 'user']) {
//         final t = _findToken(data[k]);
//         if (t != null) return t;
//       }
//     }
//     return null;
//   }

//   /// Reads an ORDS collection (`items` + `next.$ref` paging) fully.
//   Future<List<Map<String, dynamic>>> _getAll(String firstUrl,
//       {String? token}) async {
//     final out = <Map<String, dynamic>>[];
//     final seenUrls = <String>{};
//     String? url = firstUrl;
//     var guard = 0;

//     while (url != null && seenUrls.add(url) && guard++ < 100) {
//       final data = await _send(
//           () => _client.get(Uri.parse(url!), headers: _headers(token: token, json: false)));

//       List? items;
//       if (data is List) {
//         items = data;
//       } else if (data is Map) {
//         items = (data['items'] ?? data['data'] ?? data['results']) as List?;
//       }
//       for (final e in items ?? const []) {
//         if (e is Map) out.add(Map<String, dynamic>.from(e));
//       }

//       String? next;
//       if (data is Map) {
//         final n = data['next'];
//         if (n is Map && n[r'$ref'] != null) next = n[r'$ref'].toString();
//         if (data['hasMore'] == false) next = null;
//       }
//       if ((items ?? const []).isEmpty) next = null;
//       url = next;
//     }
//     return out;
//   }

//   /* ------------------------------ locations ------------------------------ */

  

// Future<List<MartLocation>> fetchLocations() async {
//   final response = await http.get(
//     Uri.parse('http://tapex.mezangrp.com/ords/hrms/ba-sales-v2/locations/list/'),
//     headers: {
//       'Accept': 'application/json',
//     },
//   );

//   if (response.statusCode != 200) {
//     throw ApiException(
//       'Failed to load locations. HTTP ${response.statusCode}',
//     );
//   }

// final Map<String, dynamic> data = jsonDecode(response.body);

// if (data['success'] != true) {
//   throw Exception(
//     data['message']?.toString() ?? 'Failed to fetch locations',
//   );
// }

// final List<dynamic> items = data['locations'] as List<dynamic>? ?? [];

// return items.map((item) {
//   return MartLocation.fromJson(
//     Map<String, dynamic>.from(item as Map),
//   );
// }).toList();
// }

//   /* -------------------------------- auth -------------------------------- */

//   Future<String> signup({
//     required String fullName,
//     required String email,
//     required String cnic,
//     required String password,
//     required String confirmPassword,
//     required int locationId,
//   }) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(ApiConfig.signup),
//           headers: _headers(),
//           body: jsonEncode({
//             'full_name': fullName,
//             'email': email,
//             'cnic': cnic,
//             'password': password,
//             'confirm_password': confirmPassword,
//             'role': 'BA',
//             'location_id': locationId,
//           }),
//         ));
//     return _messageOf(data) ?? 'Account created. Please login.';
//   }

//   Future<LoginResult> login({
//     required String email,
//     required String password,
//   }) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(ApiConfig.login),
//           headers: _headers(),
//           body: jsonEncode({'email': email, 'password': password}),
//         ));

//     final token = _findToken(data);
//     if (token == null) {
//       throw const ApiException('Login succeeded but no token was returned.');
//     }
//     final map = _findMap(data) ?? {};
//     final user = AppUser.fromJson(map);
//     return LoginResult(
//       token,
//       user.email.isEmpty ? user.mergeWith(AppUser(id: '', fullName: 'BA', email: email)) : user,
//     );
//   }

//   Future<AppUser> fetchProfile(String token) async {
//     final data = await _send(() => _client.get(
//           Uri.parse(ApiConfig.profile),
//           headers: _headers(token: token, json: false),
//         ));
//     final map = _findMap(data);
//     if (map == null) throw const ApiException('Could not read profile.');
//     return AppUser.fromJson(map);
//   }

//   /* ----------------------------- attendance ----------------------------- */

//   Future<String> attendanceIn({
//     required String token,
//     required double latitude,
//     required double longitude,
//        required int locationId,
//   }) =>
//       _attendance(ApiConfig.attendanceIn, token, latitude, longitude,locationId,
//           'Attendance IN marked.');

//   Future<String> attendanceOut({
//     required String token,
//     required double latitude,
//     required double longitude,
//        required int locationId,
//   }) =>
//       _attendance(ApiConfig.attendanceOut, token, latitude, longitude,locationId,
//           'Attendance OUT marked.');

//   Future<String> _attendance(String url, String token, double lat, double lng,int locationId,
//       String fallback) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(url),
//           headers: _headers(token: token),
//           body: jsonEncode({'latitude': lat, 'longitude': lng}),
//         ));
//     return _messageOf(data) ?? fallback;
//   }

//   /* -------------------------------- sales -------------------------------- */

//   /// Active SKUs only (inactive ones are skipped).
//   Future<List<Sku>> fetchSkus() async {
//     final rows = await _getAll(ApiConfig.skuList);
//     final seen = <int>{};
//     final out = <Sku>[];
//     for (final r in rows) {
//       if (!Sku.isActive(r)) continue;
//       final s = Sku.fromJson(r);
//       if (s.skuId == 0 || !seen.add(s.skuId)) continue;
//       out.add(s);
//     }
//     out.sort((a, b) {
//       final g = a.group.toLowerCase().compareTo(b.group.toLowerCase());
//       return g != 0 ? g : a.itemName.toLowerCase().compareTo(b.itemName.toLowerCase());
//     });
//     return out;
//   }

//   Future<String> enterSales({
//     required String token,
//     required int locationId,
//     required String saleDate, // yyyy-MM-dd
//     required Map<int, int> quantities, // sku_id -> qty
//   }) async {
//     final data = await _send(() => _client.post(
//           Uri.parse(ApiConfig.enterSales),
//           headers: _headers(token: token),
//           body: jsonEncode({
//             'location_id': locationId,
//             'sale_date': saleDate,
//             'items': [
//               for (final e in quantities.entries)
//                 {'sku_id': e.key, 'quantity': e.value},
//             ],
//           }),
//         ));
//     return _messageOf(data) ?? 'Sales saved.';
//   }
// }
