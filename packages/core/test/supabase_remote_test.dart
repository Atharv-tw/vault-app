import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vault_core/vault_core.dart';

void main() {
  /// A signed-in device whose access token has run out, talking to an auth
  /// server that answers a refresh with [status] and [body].
  (SupabaseRemote, Store) expiredSession(int status, String body) {
    final store = Store(openMemoryDb())
      ..setMeta('supabase_refresh_token', 'refresh-1')
      ..setMeta('supabase_access_token', 'old')
      ..setMeta('supabase_expires_at', DateTime.utc(2020).toIso8601String());
    final client = MockClient((req) async {
      if (req.url.path == '/auth/v1/token') return http.Response(body, status);
      return http.Response('[]', 200);
    });
    final remote = SupabaseRemote(store, client: client)..configure(url: 'https://x.supabase.co', anonKey: 'anon');
    return (remote, store);
  }

  for (final (status, body) in [
    (503, 'Service Unavailable'),
    (502, '<html>Bad gateway</html>'),
    (500, jsonEncode({'error': 'unexpected_failure'})),
    (429, jsonEncode({'error_code': 'over_request_rate_limit'})),
  ]) {
    test('an HTTP $status during a refresh keeps the session for the next sync', () async {
      final (remote, store) = expiredSession(status, body);
      await expectLater(
        remote.pull('tasks', null),
        throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('will try again'))),
      );
      expect(remote.signedIn, isTrue);
      expect(store.getMeta('supabase_refresh_token'), 'refresh-1');
    });
  }

  for (final body in [
    jsonEncode({'error': 'invalid_grant', 'error_description': 'Invalid Refresh Token'}),
    jsonEncode({'code': 400, 'error_code': 'refresh_token_not_found', 'msg': 'Invalid Refresh Token'}),
    jsonEncode({'code': 400, 'error_code': 'refresh_token_already_used', 'msg': 'Already Used'}),
  ]) {
    test('a rejected refresh token signs the device out: $body', () async {
      final (remote, store) = expiredSession(400, body);
      await expectLater(
        remote.pull('tasks', null),
        throwsA(isA<SyncException>().having((e) => e.message, 'message', contains('Signed out'))),
      );
      expect(remote.signedIn, isFalse);
    });
  }
}
