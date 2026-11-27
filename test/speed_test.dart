import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/voice/speech_output.dart';

void main() {
  group('speech is split so long replies start playing sooner', () {
    test('short replies stay one piece (one request, cacheable)', () {
      expect(SpeechOutput.chunkForSpeech('WhatsApp is open, sir. What next?', 450), ['WhatsApp is open, sir. What next?']);
    });

    test('a long reply speaks its first sentence first', () {
      const text = 'The Eiffel Tower is in Paris, France. It was built in 1889 for the World Fair and is about '
          '330 metres tall. Millions of people visit it every year, and it is lit up every night with thousands '
          'of lights that sparkle on the hour.';
      final parts = SpeechOutput.chunkForSpeech(text, 450);
      expect(parts.first, 'The Eiffel Tower is in Paris, France.');
      expect(parts.join(' '), text); // nothing lost or reordered
    });

    test('very long text still respects the size limit', () {
      final text = List.filled(30, 'This is one sentence of a long answer.').join(' ');
      final parts = SpeechOutput.chunkForSpeech(text, 450);
      expect(parts.length, greaterThan(2));
      expect(parts.every((p) => p.length <= 450), isTrue);
      expect(parts.join(' ').replaceAll(RegExp(r'\s+'), ' '), text);
    });

    test('a long first sentence is not split mid-way', () {
      final text = '${List.filled(25, 'word').join(' ')} end. Second sentence here for the rest of the reply, '
          'which keeps going for a while so the whole text is over two hundred characters long overall.';
      final parts = SpeechOutput.chunkForSpeech(text, 450);
      expect(parts.join(' '), text);
    });
  });
}
