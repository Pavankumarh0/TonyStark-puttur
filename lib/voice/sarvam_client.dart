import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class SarvamException implements Exception {
  final String message;
  final int? status;
  SarvamException(this.message, {this.status});
  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

/// Sarvam AI REST client: Saaras (speech-to-text) and Bulbul (text-to-speech).
/// Only receives audio AFTER the offline wake word fired or the user tapped the mic.
class SarvamClient {
  static const _base = 'https://api.sarvam.ai';
  http.Client _client = http.Client();

  void cancelInFlight() {
    _client.close();
    _client = http.Client();
  }

  Future<String> transcribe({
    required String apiKey,
    required Uint8List wav,
    String model = 'saaras:v4',
    String languageCode = 'en-IN',
    String mode = 'transcribe',
    List<String> keyterms = const [],
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/speech-to-text'))
      ..headers['api-subscription-key'] = apiKey
      ..fields['model'] = model
      ..fields['language_code'] = languageCode
      ..files.add(http.MultipartFile.fromBytes('file', wav, filename: 'audio.wav'));
    if (model.startsWith('saaras')) req.fields['mode'] = mode;
    if (keyterms.isNotEmpty && model == 'saaras:v4') {
      req.fields['keyterms'] = jsonEncode(keyterms.take(50).map((k) => k.length > 64 ? k.substring(0, 64) : k).toList());
    }
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 25)));
    } on TimeoutException {
      throw SarvamException('Sarvam speech-to-text timed out');
    } on http.ClientException catch (e) {
      throw SarvamException('Network error talking to Sarvam: ${e.message}');
    }
    final j = _json(res.body);
    if (res.statusCode != 200) throw SarvamException(_err(j) ?? 'Speech-to-text failed', status: res.statusCode);
    return ((j?['transcript'] as String?) ?? '').trim();
  }

  Future<Uint8List> synthesize({
    required String apiKey,
    required String text,
    String model = 'bulbul:v3',
    String speaker = 'shubh',
    String languageCode = 'en-IN',
    double pace = 1.0,
  }) async {
    final body = {
      'text': text.length > 2500 ? text.substring(0, 2500) : text,
      'language_code': languageCode,
      'model': model,
      'speaker': speaker,
      'pace': pace.clamp(0.5, 2.0),
      'speech_sample_rate': 22050,
      'enable_preprocessing': true,
    };
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse('$_base/text-to-speech'),
              headers: {'api-subscription-key': apiKey, 'Content-Type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw SarvamException('Sarvam text-to-speech timed out');
    } on http.ClientException catch (e) {
      throw SarvamException('Network error talking to Sarvam: ${e.message}');
    }
    final j = _json(res.body);
    if (res.statusCode != 200) throw SarvamException(_err(j) ?? 'Text-to-speech failed', status: res.statusCode);
    final audios = j?['audios'] as List?;
    if (audios == null || audios.isEmpty) throw SarvamException('Sarvam returned no audio');
    return base64Decode(audios.first as String);
  }

  static Map<String, dynamic>? _json(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static String? _err(Map<String, dynamic>? j) {
    final e = j?['error'];
    if (e is Map) return e['message'] as String?;
    if (e is String) return e;
    return j?['message'] as String? ?? j?['detail']?.toString();
  }
}
