import 'package:flutter_test/flutter_test.dart';
import 'package:noise_map_collector/services/csv_data_service.dart';

void main() {
  test('buildSessionCsv writes header and row in expected format', () {
    final csv = CsvDataService.buildSessionCsv(
      timestampUtc: DateTime.utc(2026, 4, 26, 12, 34, 56, 789),
      longitude: 98.6734567,
      latitude: 3.5952345,
      altitudeMeters: 12.34,
      noiseDb: 72.44,
    );

    expect(csv, contains(CsvDataService.csvHeader));
    expect(
      csv,
      contains('2026-04-26T12:34:56.789Z,98.673457,3.595235,12.3,72.4'),
    );
  });

  test('mergeCsvTexts keeps one header and merges all rows', () {
    const first = '''
${CsvDataService.csvHeader}
2026-04-26T12:00:00.000Z,98.1,3.1,10.0,70.0
''';
    const second = '''
\ufeff${CsvDataService.csvHeader}
2026-04-26T12:05:00.000Z,98.2,3.2,11.0,71.0
''';

    final merged = CsvDataService.mergeCsvTexts([first, second]);
    final lines = merged
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();

    expect(lines.first, CsvDataService.csvHeader);
    expect(lines.where((line) => line == CsvDataService.csvHeader), hasLength(1));
    expect(
      lines.where((line) => line.startsWith('2026-04-26T')).length,
      2,
    );
  });
}

