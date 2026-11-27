import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/core/privacy_filter.dart';

void main() {
  test('phone, email, otp are hidden and restored', () {
    final r = PrivacyFilter.redact('send my OTP 482913 to rahul@gmail.com and call 98450 12345');
    expect(r.text, isNot(contains('482913')));
    expect(r.text, isNot(contains('rahul@gmail.com')));
    expect(r.text, isNot(contains('98450 12345')));
    expect(r.restore(r.text), 'send my OTP 482913 to rahul@gmail.com and call 98450 12345');
  });
  test('+91 numbers', () => expect(PrivacyFilter.redact('call +91 9845012345').text, 'call <PHONE_1>'));
  test('card / aadhaar / PAN / UPI', () {
    final r = PrivacyFilter.redact('card 4111 1111 1111 1111, aadhaar 1234 5678 9012, PAN ABCDE1234F, pay pavan@okicici');
    for (final s in ['4111', '5678 9012', 'ABCDE1234F', 'pavan@okicici']) {
      expect(r.text, isNot(contains(s)), reason: s);
    }
  });
  test('password', () => expect(PrivacyFilter.redact('my password is Tiger@123').text, isNot(contains('Tiger@123'))));
  test('times, dates, prices, names stay', () {
    const t = 'set an alarm for 6:30 am tomorrow, buy earbuds under ₹1,999 and message Rahul on 25 December 2026';
    expect(PrivacyFilter.redact(t).text, t);
  });
  test('"write code for" is not a secret', () {
    const t = 'ask ChatGPT to write code for a login page';
    expect(PrivacyFilter.redact(t).text, t);
  });
  test('same value → same placeholder', () {
    final r = PrivacyFilter.redact('call 9845012345 and text 9845012345');
    expect(r.count, 1);
  });
}
