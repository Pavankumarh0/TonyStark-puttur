import 'package:flutter/services.dart';

/// Encryption at rest for everything private LEO stores (see android/.../Vault.kt):
/// AES-256-GCM per value, keys wrapped by a hardware-backed Android Keystore key, each value bound
/// (Associated Data) to the Android user + table + column it belongs to.
abstract class Vault {
  static const prefix = 'v1:';
  static bool isSealed(String? s) => s != null && s.startsWith(prefix);

  Future<Map<String, dynamic>> init();
  Future<List<String?>> seal(List<String?> plain, String aad);

  /// Values that fail authentication come back as null (never as garbage).
  Future<List<String?>> open(List<String?> sealed, String aad);

  /// Keyed (HMAC) search tokens, so the search index never contains readable words.
  Future<List<String>> blind(List<String> words);

  /// Destroys the keys (crypto-shredding) and creates fresh ones.
  Future<void> wipe();
  Future<List<Map<String, dynamic>>> selfTest();
  Future<Map<String, dynamic>> status();

  Future<String?> seal1(String? s, String aad) async => s == null ? null : (await seal([s], aad)).first;
  Future<String?> open1(String? s, String aad) async => s == null ? null : (await open([s], aad)).first;
}

class NativeVault extends Vault {
  static const _ch = MethodChannel('jarvis/vault');

  @override
  Future<Map<String, dynamic>> init() async => Map<String, dynamic>.from(await _ch.invokeMethod('init') as Map);
  @override
  Future<Map<String, dynamic>> status() async => Map<String, dynamic>.from(await _ch.invokeMethod('status') as Map);
  @override
  Future<List<String?>> seal(List<String?> plain, String aad) async =>
      plain.isEmpty ? const [] : (await _ch.invokeMethod('seal', {'values': plain, 'aad': aad}) as List).cast<String?>();
  @override
  Future<List<String?>> open(List<String?> sealed, String aad) async =>
      sealed.isEmpty ? const [] : (await _ch.invokeMethod('open', {'values': sealed, 'aad': aad}) as List).cast<String?>();
  @override
  Future<List<String>> blind(List<String> words) async =>
      words.isEmpty ? const [] : (await _ch.invokeMethod('blind', {'words': words}) as List).cast<String>();
  @override
  Future<void> wipe() async => _ch.invokeMethod('wipe');
  @override
  Future<List<Map<String, dynamic>>> selfTest() async =>
      [for (final r in (await _ch.invokeMethod('selfTest') as List)) Map<String, dynamic>.from(r as Map)];
}
