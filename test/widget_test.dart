import 'package:flutter_test/flutter_test.dart';
import 'package:ords_ba/Model/models.dart';

void main() {
  test('Sku parses sample item and trims names', () {
    final s = Sku.fromJson({
      'sku_id': 1010772601,
      'item_code': '101077',
      'item_name': 'BOX 150GM 60 PCS CTN',
      'blend_name': ' AWAZ',
      'sku_group': 'AWAZ',
      'con_blend_name': ' AWAZ',
      'active': 'Y',
    });
    expect(s.skuId, 1010772601);
    expect(s.blendName, 'AWAZ');
    expect(s.group, 'AWAZ');
  });

  test('MartLocation parser accepts common field spellings', () {
    final l = MartLocation.fromJson({
      'location_id': '7',
      'location_name': 'Test Mart',
      'lat': '24.8607',
      'lng': 67.0011,
    });
    expect(l.id, 7);
    expect(l.hasCoordinates, isTrue);
    expect(l.radiusMeters, MartLocation.kDefaultRadius);
  });

  test('Inactive SKUs are detected', () {
    expect(Sku.isActive({'active': 'N'}), isFalse);
    expect(Sku.isActive({'active': 'Y'}), isTrue);
  });
}
