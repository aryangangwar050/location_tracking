import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';

import '../features/tracking/location_record.dart';

class LocationApi {
  LocationApi(this.client, this.baseUrl);

  final http.Client client;
  final Uri baseUrl;
  static const _timeout = Duration(seconds: 8);

  Future<bool> reachable() async {
    try {
      final response = await client
          .get(baseUrl.resolve('health'))
          .timeout(_timeout);
      return response.statusCode == 200;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    }
  }

  Future<bool> upload(LocationRecord record) async {
    try {
      final response = await client
          .post(
            baseUrl.resolve('locations'),
            headers: {
              'Content-Type': 'application/json',
              'Idempotency-Key': record.id,
            },
            body: jsonEncode(record.toPayload()),
          )
          .timeout(_timeout);
      if (response.statusCode != 200 && response.statusCode != 201) {
        return false;
      }
      final body = jsonDecode(response.body);
      return body is Map && body['id'] == record.id;
    } on TimeoutException {
      return false;
    } on http.ClientException {
      return false;
    } on FormatException {
      return false;
    }
  }
}

class MockLocationServer {
  MockLocationServer(this.db);

  final Database db;
  bool failUploads = false;

  http.Client createClient() => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    if (request.method == 'GET' && request.url.path == '/health') {
      return http.Response('{"status":"ok"}', 200);
    }
    if (request.method == 'POST' && request.url.path == '/locations') {
      final Object? body;
      try {
        body = jsonDecode(request.body);
      } on FormatException {
        return http.Response('{"error":"invalid JSON"}', 400);
      }
      final id = request.headers['idempotency-key'];
      if (id == null ||
          body is! Map ||
          body['id'] != id ||
          body['latitude'] is! num ||
          body['longitude'] is! num ||
          body['timestamp'] is! int) {
        return http.Response(
          '{"error":"invalid location or idempotency key"}',
          400,
        );
      }
      return db.transaction((tx) async {
        final existing = await tx.query(
          'receipts',
          where: 'id = ?',
          whereArgs: [id],
        );
        if (existing.isNotEmpty) {
          return http.Response(jsonEncode({'id': id, 'duplicate': true}), 200);
        }
        if (failUploads) {
          return http.Response('{"error":"simulated upload failure"}', 503);
        }
        await tx.insert('receipts', {'id': id, 'payload': request.body});
        return http.Response(jsonEncode({'id': id, 'duplicate': false}), 201);
      });
    }
    return http.Response('{"error":"unknown route"}', 404);
  }
}
