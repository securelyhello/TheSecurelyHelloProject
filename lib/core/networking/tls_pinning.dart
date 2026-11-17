import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;

/// Certificate pinning: the server's public key must be one of [pins]
/// (base64 SHA-256 of the SubjectPublicKeyInfo, the format `openssl` and
/// HPKP use). The check runs on the TLS socket right after the handshake,
/// after normal CA validation and before any request byte (or the session
/// token) is sent.
///
/// Pin the server key and at least one backup key: a certificate renewed
/// with a new key will otherwise lock every installed app out.
class TlsPinning {
  final Set<String> pins;

  /// Trust store for the handshake; null means the platform's roots.
  final SecurityContext? context;
  const TlsPinning(this.pins, {this.context});

  /// From a comma-separated list; empty means pinning is off.
  factory TlsPinning.parse(String raw) => TlsPinning({
        for (final p in raw.split(',')) if (p.trim().isNotEmpty) p.trim(),
      });

  bool get enabled => pins.isNotEmpty;

  /// The pin of a DER certificate.
  static String pinOf(Uint8List der) => base64Encode(hash.sha256.convert(spkiOf(der)).bytes);

  bool accepts(X509Certificate? cert) => cert != null && pins.contains(pinOf(cert.der));

  /// An HttpClient that connects directly and checks the pin on every new
  /// connection. Without pins, a plain client.
  HttpClient httpClient() {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    if (!enabled) return client;
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      if (uri.scheme != 'https' && uri.scheme != 'wss') {
        throw const TlsException('Pinned connections must use TLS');
      }
      final task = await SecureSocket.startConnect(uri.host, uri.port == 0 ? 443 : uri.port,
          context: context);
      return ConnectionTask.fromSocket(
        task.socket.then((socket) {
          if (!accepts(socket.peerCertificate)) {
            socket.destroy();
            throw const TlsException("The server's key doesn't match this app's pinned keys");
          }
          return socket;
        }),
        task.cancel,
      );
    };
    return client;
  }
}

/// The DER SubjectPublicKeyInfo inside an X.509 certificate.
///
/// Certificate ::= SEQUENCE { tbsCertificate, ... }
/// TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
///   signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
Uint8List spkiOf(Uint8List der) {
  final cert = _Der(der, 0).element();
  final tbs = _Der(der, cert.contentStart).element();
  var pos = tbs.contentStart;
  var el = _Der(der, pos).element();
  if (el.tag == 0xa0) {
    pos = el.end;
    el = _Der(der, pos).element();
  }
  // serialNumber, signature, issuer, validity, subject.
  for (var i = 0; i < 5; i++) {
    pos = el.end;
    el = _Der(der, pos).element();
  }
  if (el.tag != 0x30) throw const FormatException('No SubjectPublicKeyInfo');
  return Uint8List.sublistView(der, el.start, el.end);
}

class _Element {
  final int tag, start, contentStart, end;
  const _Element(this.tag, this.start, this.contentStart, this.end);
}

class _Der {
  final Uint8List b;
  final int pos;
  const _Der(this.b, this.pos);

  _Element element() {
    if (pos + 2 > b.length) throw const FormatException('Truncated DER');
    final tag = b[pos];
    var len = b[pos + 1];
    var p = pos + 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0 || n > 4 || p + n > b.length) throw const FormatException('Bad DER length');
      len = 0;
      for (var i = 0; i < n; i++) {
        len = (len << 8) | b[p++];
      }
    }
    if (p + len > b.length) throw const FormatException('Truncated DER');
    return _Element(tag, pos, p, p + len);
  }
}
