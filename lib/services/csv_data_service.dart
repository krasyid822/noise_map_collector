import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CsvInboxItem {
  CsvInboxItem({
    required this.file,
    required this.originalName,
    required this.importedAt,
    required this.sizeBytes,
    required this.preview,
  });

  final File file;
  final String originalName;
  final DateTime importedAt;
  final int sizeBytes;
  final String preview;

  String get fileName => file.path.split(Platform.pathSeparator).last;

  static Future<CsvInboxItem> fromFile({
    required File file,
    required String originalName,
    int previewLineLimit = 8,
  }) async {
    final stat = await file.stat();
    return CsvInboxItem(
      file: file,
      originalName: originalName,
      importedAt: stat.modified,
      sizeBytes: stat.size,
      preview: await CsvDataService.previewCsvText(file, lineLimit: previewLineLimit),
    );
  }
}

class CsvDataService {
  CsvDataService();

  static const String csvHeader =
      'timestamp_utc,longitude,latitude,altitude_m,noise_db';
  static const String rollingFileName = 'noise_data.csv';
  static const String inboxDirectoryName = 'csv_inbox';
  static const String mergedFilePrefix = 'merged_noise_data_';
  static const String sessionFilePrefix = 'noise_session_';

  static String buildTimestampToken(DateTime dateTime) {
    final utc = dateTime.toUtc();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    String threeDigits(int value) => value.toString().padLeft(3, '0');

    return [
      utc.year.toString().padLeft(4, '0'),
      twoDigits(utc.month),
      twoDigits(utc.day),
      '_',
      twoDigits(utc.hour),
      twoDigits(utc.minute),
      twoDigits(utc.second),
      '_',
      threeDigits(utc.millisecond),
    ].join();
  }

  static String buildSessionRow({
    required DateTime timestampUtc,
    required double longitude,
    required double latitude,
    required double altitudeMeters,
    required double noiseDb,
  }) {
    return [
      timestampUtc.toUtc().toIso8601String(),
      longitude.toStringAsFixed(6),
      latitude.toStringAsFixed(6),
      altitudeMeters.toStringAsFixed(1),
      noiseDb.toStringAsFixed(1),
    ].join(',');
  }

  static String buildSessionCsv({
    required DateTime timestampUtc,
    required double longitude,
    required double latitude,
    required double altitudeMeters,
    required double noiseDb,
  }) {
    final buffer = StringBuffer()..writeln(csvHeader);
    buffer.writeln(
      buildSessionRow(
        timestampUtc: timestampUtc,
        longitude: longitude,
        latitude: latitude,
        altitudeMeters: altitudeMeters,
        noiseDb: noiseDb,
      ),
    );
    return buffer.toString();
  }

  static bool _isHeaderLine(String line) {
    return line.trimLeft().replaceFirst('\ufeff', '').toLowerCase() ==
        csvHeader.toLowerCase();
  }

  static String mergeCsvTexts(Iterable<String> csvTexts) {
    final rows = <String>[];

    for (final csvText in csvTexts) {
      final lines = csvText.split(RegExp(r'\r?\n'));
      for (final rawLine in lines) {
        final normalized = rawLine.replaceFirst('\ufeff', '');
        if (normalized.trim().isEmpty) continue;
        if (_isHeaderLine(normalized)) continue;
        rows.add(normalized);
      }
    }

    final buffer = StringBuffer()..writeln(csvHeader);
    for (final row in rows) {
      buffer.writeln(row);
    }
    return buffer.toString();
  }

  Future<Directory> getExportDirectory() async {
    final externalDirectory = await getExternalStorageDirectory();
    if (externalDirectory != null) {
      return externalDirectory;
    }

    return getApplicationDocumentsDirectory();
  }

  Future<Directory> getInboxDirectory() async {
    final exportDirectory = await getExportDirectory();
    final inboxDirectory = Directory(
      '${exportDirectory.path}${Platform.pathSeparator}$inboxDirectoryName',
    );

    if (!await inboxDirectory.exists()) {
      await inboxDirectory.create(recursive: true);
    }

    return inboxDirectory;
  }

  Future<File> saveSessionCsv({
    required DateTime timestampUtc,
    required double longitude,
    required double latitude,
    required double altitudeMeters,
    required double noiseDb,
  }) async {
    final exportDirectory = await getExportDirectory();
    final fileName =
        '$sessionFilePrefix${buildTimestampToken(timestampUtc)}.csv';
    final file = File(
      '${exportDirectory.path}${Platform.pathSeparator}$fileName',
    );

    await file.writeAsString(
      buildSessionCsv(
        timestampUtc: timestampUtc,
        longitude: longitude,
        latitude: latitude,
        altitudeMeters: altitudeMeters,
        noiseDb: noiseDb,
      ),
    );

    return file;
  }

  Future<List<File>> collectCsvFiles() async {
    final inboxItems = await listInboxItems();
    return inboxItems.map((item) => item.file).toList();
  }

  Future<List<CsvInboxItem>> listInboxItems() async {
    final items = <CsvInboxItem>[];

    // 1. Cek file hasil rekaman Collector sendiri (Rolling File)
    final exportDir = await getExportDirectory();
    final rollingFile = File('${exportDir.path}${Platform.pathSeparator}$rollingFileName');
    if (await rollingFile.exists()) {
      items.add(
        await CsvInboxItem.fromFile(
          file: rollingFile,
          originalName: 'Collector (Local Data)',
        ),
      );
    }

    // 2. Cek folder Inbox (file dari WhatsApp/luar)
    final inboxDirectory = await getInboxDirectory();
    if (!await inboxDirectory.exists()) return items;

    final entities = await inboxDirectory.list(followLinks: false).toList();

    final csvFiles = entities.whereType<File>().where((file) {
      final fileName = _basename(file.path).toLowerCase();
      return fileName.endsWith('.csv');
    }).toList();

    csvFiles.sort(
      (left, right) => left.statSync().modified.compareTo(
            right.statSync().modified,
          ),
    );

    for (final file in csvFiles) {
      items.add(
        await CsvInboxItem.fromFile(
          file: file,
          originalName: _basename(file.path),
        ),
      );
    }

    return items;
  }

  Future<File> createMergedCsv({List<File>? sourceFiles}) async {
    final files = sourceFiles ?? await collectCsvFiles();
    final csvTexts = <String>[];

    for (final file in files) {
      csvTexts.add(await file.readAsString());
    }

    final exportDirectory = await getExportDirectory();
    final outputName =
        '$mergedFilePrefix${buildTimestampToken(DateTime.now().toUtc())}.csv';
    final mergedFile = File(
      '${exportDirectory.path}${Platform.pathSeparator}$outputName',
    );

    await mergedFile.writeAsString(mergeCsvTexts(csvTexts));
    return mergedFile;
  }

  Future<File> mergeInboxCsvFiles({List<CsvInboxItem>? items}) async {
    final inboxItems = items ?? await listInboxItems();
    return createMergedCsv(sourceFiles: inboxItems.map((item) => item.file).toList());
  }

  Future<List<CsvInboxItem>> importSharedCsvFiles(List<String> sourcePaths) async {
    final inboxDirectory = await getInboxDirectory();
    final importedItems = <CsvInboxItem>[];

    for (var index = 0; index < sourcePaths.length; index++) {
      final sourcePath = sourcePaths[index];
      
      // Jika masih berupa content:// URI, kita log saja karena butuh penanganan native
      if (sourcePath.startsWith('content://')) {
        print('Warning: Cannot import content:// URI directly with dart:io. URI: $sourcePath');
        continue;
      }

      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) continue;

      var fileName = _basename(sourceFile.path);
      // Pastikan nama file tujuan berakhiran .csv agar terdeteksi oleh listInboxItems
      if (!fileName.toLowerCase().endsWith('.csv')) {
        fileName = '$fileName.csv';
      }

      final importedName =
          'received_${buildTimestampToken(DateTime.now().toUtc())}_${index + 1}_$fileName';
      final destination = File(
        '${inboxDirectory.path}${Platform.pathSeparator}$importedName',
      );
      
      final copiedFile = await sourceFile.copy(destination.path);
      importedItems.add(
        await CsvInboxItem.fromFile(file: copiedFile, originalName: fileName),
      );
    }

    return importedItems;
  }

  Future<void> deleteInboxItem(CsvInboxItem item) async {
    if (await item.file.exists()) {
      await item.file.delete();
    }
  }

  static Future<String> previewCsvText(File file, {int lineLimit = 8}) async {
    if (!await file.exists()) return '';

    try {
        final lines = await file.readAsLines();
        if (lines.isEmpty) return '';

        final previewLines = lines.take(lineLimit).toList();
        return previewLines.join('\n');
    } catch (e) {
        return 'Error reading file: $e';
    }
  }

  static String _basename(String path) {
    return path.split(Platform.pathSeparator).last;
  }
}
