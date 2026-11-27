import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis/orchestrator/jarvis_orchestrator.dart';

void main() {
  test('product title is the main line, not its subtitle', () {
    final p = JarvisOrchestrator.parseProducts([
      'Sponsored',
      'USB-A to Type-C & Type-C to Type-C Data Cable Combo…',
      'Charging Cables, 2-in-1 Co…',
      '₹249',
      'FREE delivery Wed, 2 Dec',
      'Add to cart',
      '120W Super Dart Fast Charging USB to Type C Da…',
      'USB Type A',
      '₹299',
    ]);
    expect(p.length, 2);
    expect(p[0].title, startsWith('USB-A to Type-C'));
    expect(p[0].price, 249);
    expect(p[1].title, startsWith('120W Super Dart'));
  });

  test('cart badge count is read from the screen', () {
    expect(JarvisOrchestrator.cartCount('[5] Button "Cart 3 items" (tap)'), 3);
    expect(JarvisOrchestrator.cartCount('[5] Text "4 items in cart" ()'), 4);
    expect(JarvisOrchestrator.cartCount('[1] Button "Add to cart" (tap)'), isNull);
  });

  test('wishlist / feedback buttons are never taken as product names', () {
    final p = JarvisOrchestrator.parseProducts([
      'Heart to save an item to your list',
      'View Sponsored information or leave ad feedback',
      '₹293.50',
    ]);
    expect(p.single.short, 'result 1'); // priced, but never named after the wishlist button
  });

  test('real Amazon results (titles not exposed): bare prices become results, M.R.P skipped', () {
    final lines = 'usb c cable ¦ Results ¦ Heart to save an item to your list ¦ View Sponsored information or leave ad feedback ¦ '
            'Charging Cables, 2-in-1 Combo, USB-A Included, Dual Cable Set ¦ ₹249 ¦ FREE delivery ¦ Wed, 2 Dec ¦ USB Type A ¦ ₹299 ¦ '
            'Amazon\'s Choice ¦ USB Type C ¦ 4.3 out of 5 stars ¦ (8.9K) ¦ 7K+ bought in past month ¦ ₹199 ¦ M.R.P: ₹999 ¦ (80% off)'
        .split(' ¦ ');
    final p = JarvisOrchestrator.parseProducts(lines);
    expect(p.map((x) => x.price), [249, 299, 199]);
    expect(p[0].short, 'Charging Cables');
    expect(p[1].short, 'result 2');
  });
}

