import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';

import 'package:securelyhello/core/networking/directory_service.dart';
import 'package:securelyhello/core/networking/tls_pinning.dart';

// test/fixtures/tls_test_cert.pem, pin computed with:
// openssl x509 -pubkey -noout | openssl pkey -pubin -outform der |
//   openssl dgst -sha256 -binary | base64
const _pin = 'e6GcJ7ekUbZ8ct8BKUud4V59ZrZQ833oh/e6DNBhQIc=';

void main() {
  late HttpServer server;
  late SecurityContext trust;
  var requests = 0;

  setUpAll(() async {
    final serverCtx = SecurityContext()
      ..useCertificateChain('test/fixtures/tls_test_cert.pem')
      ..usePrivateKey('test/fixtures/tls_test_key.pem');
    server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, serverCtx);
    server.listen((req) {
      requests++;
      req.response
        ..write('ok')
        ..close();
    });
    trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('test/fixtures/tls_test_cert.pem');
  });

  tearDownAll(() => server.close(force: true));

  Uri url() => Uri.parse('https://localhost:${server.port}/api/me');

  test('the SPKI pin matches openssl', () async {
    final socket = await SecureSocket.connect('localhost', server.port, context: trust);
    expect(TlsPinning.pinOf(socket.peerCertificate!.der), _pin);
    socket.destroy();
  });

  test('the right pin connects', () async {
    final client = IOClient(TlsPinning({_pin}, context: trust).httpClient());
    final res = await client.get(url());
    expect(res.body, 'ok');
    client.close();
  });

  test('a wrong pin fails before the request is sent', () async {
    final before = requests;
    final client = IOClient(
        TlsPinning({'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='}, context: trust).httpClient());
    await expectLater(
        client.get(url(), headers: {'Authorization': 'Bearer secret'}), throwsA(anything));
    expect(requests, before, reason: 'the token never reached the server');
    client.close();
  });

  test('parse ignores blanks', () {
    expect(TlsPinning.parse('').enabled, isFalse);
    expect(TlsPinning.parse(' a= , ,b= ').pins, {'a=', 'b='});
  });

  group('server address', () {
    Uri parse(String u, {bool release = true, bool pinned = false}) =>
        DirectoryService.parseBaseUrl(u, release: release, pinned: pinned);

    test('https is always fine', () {
      expect(parse('https://chat.example.com').host, 'chat.example.com');
    });

    test('plain http only for this machine in release builds', () {
      expect(parse('http://127.0.0.1:8787').port, 8787);
      expect(parse('http://localhost:8787').host, 'localhost');
      expect(() => parse('http://chat.example.com'), throwsArgumentError);
      expect(() => parse('http://192.168.1.20:8787'), throwsArgumentError);
    });

    test('debug builds also allow private networks and the emulator host', () {
      expect(parse('http://10.0.2.2:8787', release: false).host, '10.0.2.2');
      expect(parse('http://192.168.1.20:8787', release: false).host, '192.168.1.20');
      expect(() => parse('http://chat.example.com', release: false), throwsArgumentError);
      expect(() => parse('http://8.8.8.8', release: false), throwsArgumentError);
    });

    test('pins need https', () {
      expect(() => parse('http://127.0.0.1:8787', pinned: true), throwsArgumentError);
    });

    test('rejects junk', () {
      expect(() => parse(''), throwsArgumentError);
      expect(() => parse('ftp://x'), throwsArgumentError);
      expect(() => parse('https://'), throwsArgumentError);
    });
  });
}
