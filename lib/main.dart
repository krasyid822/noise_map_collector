import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_sharing_intent/flutter_sharing_intent.dart';
import 'package:flutter_sharing_intent/model/sharing_file.dart';

import 'services/csv_data_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Noise Map Collector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Noise Map Collector'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const platform = MethodChannel('trpl6a.rasyid.noise_map_collector/content_resolver');
  final NoiseMeter noiseMeter = NoiseMeter();
  final CsvDataService csvDataService = CsvDataService();
  StreamSubscription<NoiseReading>? subscription;
  StreamSubscription<List<SharedFile>>? sharedMediaSubscription;
  final List<double> samples = [];
  final List<CsvInboxItem> _inboxItems = [];

  Map<Permission, PermissionStatus> permissionStatuses = const {};
  int _selectedTabIndex = 0;

  double currentMeanDb = 0;
  double currentMaxDb = 0;
  double currentLeq = 0;
  bool isMeasuring = false;
  bool isSaving = false;
  bool isCsvBusy = false;
  String statusMessage = 'Siap mengumpulkan data';
  Position? lastPosition;
  String? lastSavedTimestamp;
  String? lastSavedPath;
  String? lastMergedPath;
  int? lastMergedFileCount;
  bool _inboxLoaded = false;

  @override
  void initState() {
    super.initState();
    requestPermissions();
    _bootstrapCsvTools();
  }

  @override
  void dispose() {
    subscription?.cancel();
    sharedMediaSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeInbox() async {
    if (!mounted) return;
    setState(() {
      _inboxLoaded = false;
    });

    try {
      final items = await csvDataService.listInboxItems();
      if (!mounted) return;
      setState(() {
        _inboxItems
          ..clear()
          ..addAll(items);
        _inboxLoaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _inboxLoaded = true;
        statusMessage = 'Gagal memuat inbox CSV: $error';
      });
    }
  }

  Future<void> _bootstrapCsvTools() async {
    // Cek apakah file lokal/merge sudah ada untuk menampilkan tombol share
    final exportDir = await csvDataService.getExportDirectory();
    final rollingFile = File('${exportDir.path}${Platform.pathSeparator}${CsvDataService.rollingFileName}');
    if (await rollingFile.exists()) {
      setState(() {
        lastSavedPath = rollingFile.path;
      });
    }

    await _initializeInbox();
    await _listenForSharedCsv();
  }

  Future<void> _listenForSharedCsv() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    print('DEBUG: Memulai _listenForSharedCsv');

    try {
      final initialMedia = await FlutterSharingIntent.instance.getInitialSharing();
      print('DEBUG: initialMedia length: ${initialMedia.length}');
      if (initialMedia.isNotEmpty) {
        for (var file in initialMedia) {
          print('DEBUG: initialMedia file: ${file.value}, type: ${file.type}');
        }
        await _importSharedMedia(initialMedia, sourceLabel: 'share awal');
      }
    } catch (e) {
      print('DEBUG: Error getInitialSharing: $e');
    }

    sharedMediaSubscription = FlutterSharingIntent.instance.getMediaStream().listen(
      (List<SharedFile> mediaFiles) {
        print('DEBUG: Stream mediaFiles length: ${mediaFiles.length}');
        for (var file in mediaFiles) {
          print('DEBUG: Stream file: ${file.value}, type: ${file.type}');
        }
        _importSharedMedia(mediaFiles, sourceLabel: 'share masuk');
      },
      onError: (Object error) {
        print('DEBUG: Stream error: $error');
        if (!mounted) return;
        setState(() {
          statusMessage = 'Gagal menerima CSV: $error';
        });
      },
    );
  }

  Future<void> _importSharedMedia(
    List<SharedFile> mediaFiles, {
    required String sourceLabel,
  }) async {
    print('DEBUG: _importSharedMedia dari $sourceLabel, jumlah: ${mediaFiles.length}');

    final List<String> csvPaths = [];
    
    for (var file in mediaFiles) {
      String? path = file.value;
      if (path == null) continue;

      final isCsvExtension = path.toLowerCase().endsWith('.csv');
      final mimeType = file.mimeType?.toLowerCase() ?? '';
      final isCsvMime = mimeType.contains('csv') || 
                        mimeType.contains('comma-separated') ||
                        mimeType.contains('excel');
      
      final isCsvType = file.type == SharedMediaType.FILE || 
                        file.type == SharedMediaType.URL ||
                        file.type == SharedMediaType.TEXT;

      final isContentUri = path.startsWith('content://');
      
      // Jika content:// URI, kita terima saja karena sudah difilter oleh AndroidManifest
      final accepted = isCsvExtension || (isCsvType && (isCsvMime || isContentUri));
      print('DEBUG: Memeriksa file: $path, Mime: $mimeType, Type: ${file.type}, isContent: $isContentUri -> Accepted: $accepted');
      
      if (accepted) {
        if (path.startsWith('content://')) {
          try {
            final String resolvedPath = await platform.invokeMethod('resolveContentUri', {'uri': path});
            csvPaths.add(resolvedPath);
            print('DEBUG: Resolved content URI to: $resolvedPath');
          } catch (e) {
            print('DEBUG: Failed to resolve content URI: $e');
          }
        } else {
          csvPaths.add(path);
        }
      }
    }

    if (csvPaths.isEmpty) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Tidak ada file CSV dari $sourceLabel';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      isCsvBusy = true;
      statusMessage = 'Mengimpor ${csvPaths.length} file CSV dari $sourceLabel...';
    });

    try {
      final importedItems = await csvDataService.importSharedCsvFiles(csvPaths);
      final items = await csvDataService.listInboxItems();

      if (!mounted) return;
      setState(() {
        _inboxItems
          ..clear()
          ..addAll(items);
        _selectedTabIndex = 1;
        statusMessage =
            'Berhasil mengimpor ${importedItems.length} file CSV ke CSV Tools';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Gagal mengimpor CSV dari $sourceLabel: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isCsvBusy = false;
        });
      }
    }
  }

  Future<void> requestPermissions() async {
    try {
      final result = await [
        Permission.microphone,
        Permission.location,
        Permission.storage,
      ].request();

      if (!mounted) return;
      setState(() {
        permissionStatuses = result;
        statusMessage = _hasRequiredPermissions
            ? 'Izin utama tersedia'
            : 'Mohon lengkapi izin microphone dan lokasi';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Gagal meminta izin: $error';
      });
    }
  }

  bool get _microphoneGranted =>
      permissionStatuses[Permission.microphone]?.isGranted ?? false;

  bool get _locationGranted =>
      permissionStatuses[Permission.location]?.isGranted ?? false;

  bool get _storageGranted =>
      permissionStatuses[Permission.storage]?.isGranted ?? false;

  bool get _hasRequiredPermissions => _microphoneGranted && _locationGranted;

  bool get _canStart =>
      _hasRequiredPermissions && !isMeasuring && !isSaving && !isCsvBusy;

  bool get _canStop => isMeasuring && !isSaving;

  bool get _canMerge =>
      _inboxItems.isNotEmpty && !isMeasuring && !isSaving && !isCsvBusy;

  String _permissionLabel(PermissionStatus? status) {
    if (status == null) return 'belum dicek';
    if (status.isGranted) return 'diizinkan';
    if (status.isPermanentlyDenied) return 'ditolak permanen';
    if (status.isDenied) return 'ditolak';
    return status.toString();
  }

  void addSample(double db) {
    samples.add(db);
  }

  double calculateLeq() {
    if (samples.isEmpty) return 0;

    final sum = samples.fold<double>(
      0,
      (total, db) => total + pow(10, db / 10).toDouble(),
    );
    return 10 * log(sum / samples.length) / ln10;
  }

  Future<Position> getLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Layanan lokasi/GPS belum aktif');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception('Izin lokasi ditolak');
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Izin lokasi ditolak permanen');
    }

    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
      ),
    );
  }

  Future<String> saveCSV(double leq) async {
    final position = await getLocation();
    final timestamp = DateTime.now().toUtc();
    final directory = await csvDataService.getExportDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}${CsvDataService.rollingFileName}',
    );
    final exists = await file.exists();
    final sink = file.openWrite(mode: FileMode.append);

    if (!exists) {
      sink.writeln(CsvDataService.csvHeader);
    }

    sink.writeln(
      CsvDataService.buildSessionRow(
        timestampUtc: timestamp,
        longitude: position.longitude,
        latitude: position.latitude,
        altitudeMeters: position.altitude,
        noiseDb: leq,
      ),
    );
    await sink.flush();
    await sink.close();

    if (mounted) {
      setState(() {
        lastPosition = position;
        lastSavedTimestamp = timestamp.toIso8601String();
      });
    }

    return file.path;
  }

  Future<void> _shareFile(String? path, {String? subject}) async {
    if (path == null) return;

    final file = File(path);
    if (await file.exists()) {
      await Share.shareXFiles(
        [XFile(path)],
        text: subject ?? 'Hasil pengumpulan data Noise Map Collector',
      );
    } else {
      if (!mounted) return;
      setState(() {
        statusMessage = 'File tidak ditemukan untuk dibagikan';
      });
    }
  }

  Future<void> startMeasurement() async {
    if (isMeasuring || isSaving) return;

    if (!_hasRequiredPermissions) {
      await requestPermissions();
      if (!_hasRequiredPermissions) {
        if (!mounted) return;
        setState(() {
          statusMessage = 'Izin belum cukup untuk mulai pengukuran';
        });
        return;
      }
    }

    samples.clear();
    currentMeanDb = 0;
    currentMaxDb = 0;
    currentLeq = 0;
    lastPosition = null;

    if (!mounted) return;
    setState(() {
      isMeasuring = true;
      statusMessage = 'Pengukuran dimulai';
    });

    try {
      subscription = noiseMeter.noise.listen(
        (NoiseReading reading) {
          if (!mounted) return;
          final mean = reading.meanDecibel;
          final max = reading.maxDecibel;

          setState(() {
            currentMeanDb = mean;
            currentMaxDb = max;
            if (mean.isFinite) {
              addSample(mean);
            }
            currentLeq = calculateLeq();
            statusMessage = 'Mengambil sampel: ${samples.length}/100 data';
          });

          // Mekanisme Auto-Cycle: Jika mencapai 100 sampel, simpan lalu lanjut
          if (samples.length >= 100 && !isSaving) {
            _handleAutoCycle();
          }
        },
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            statusMessage = 'Error noise meter: $error';
          });
        },
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        isMeasuring = false;
        statusMessage = 'Gagal memulai pengukuran: $error';
      });
    }
  }

  Future<void> _handleAutoCycle() async {
    if (isSaving) return;
    
    print('DEBUG: Auto-cycle triggered. Saving current batch...');
    await stopMeasurement();
    
    if (mounted) {
      print('DEBUG: Restarting measurement for next batch...');
      await startMeasurement();
      setState(() {
        statusMessage = 'Batch 100 data tersimpan. Melanjutkan...';
      });
    }
  }

  Future<void> stopMeasurement() async {
    if (!isMeasuring || isSaving) return;

    if (!mounted) return;
    setState(() {
      isSaving = true;
      statusMessage = 'Menghentikan pengukuran dan menyimpan CSV...';
    });

    try {
      await subscription?.cancel();
      subscription = null;

      final leq = calculateLeq();
      final savedPath = await saveCSV(leq);

      if (!mounted) return;
      setState(() {
        currentLeq = leq;
        lastSavedPath = savedPath;
        statusMessage = lastSavedTimestamp == null
            ? 'Data tersimpan di $savedPath'
            : 'Data tersimpan pada $lastSavedTimestamp di $savedPath';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Gagal menyimpan CSV: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isMeasuring = false;
          isSaving = false;
        });
      }
    }
  }

  Future<void> _mergeAllCsvFiles() async {
    if (!_canMerge) return;

    if (!mounted) return;
    setState(() {
      isCsvBusy = true;
      statusMessage = 'Menggabungkan semua CSV di inbox...';
    });

    try {
      if (_inboxItems.isEmpty) {
        throw Exception('Belum ada CSV inbox yang tersedia untuk digabung');
      }

      final mergedFile = await csvDataService.mergeInboxCsvFiles(
        items: _inboxItems,
      );

      if (!mounted) return;
      setState(() {
        lastMergedPath = mergedFile.path;
        lastMergedFileCount = _inboxItems.length;
        statusMessage = 'CSV gabungan dibuat dari ${_inboxItems.length} file';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Gagal menggabungkan CSV: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isCsvBusy = false;
        });
      }
    }
  }

  Future<void> _refreshInbox() async {
    if (!_canMerge) return;

    try {
      final items = await csvDataService.listInboxItems();
      if (!mounted) return;
      setState(() {
        _inboxItems
          ..clear()
          ..addAll(items);
        statusMessage = 'Inbox CSV diperbarui: ${items.length} file';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Gagal memuat inbox CSV: $error';
      });
    }
  }

  Future<void> _previewInboxItem(CsvInboxItem item) async {
    final preview = await CsvDataService.previewCsvText(item.file, lineLimit: 12);
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(item.originalName),
          content: SingleChildScrollView(
            child: Text(
              preview.isEmpty ? '(preview kosong)' : preview,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Tutup'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _deleteInboxItem(CsvInboxItem item) async {
    if (!mounted) return;
    setState(() {
      isCsvBusy = true;
      statusMessage = 'Menghapus ${item.originalName}...';
    });

    try {
      await csvDataService.deleteInboxItem(item);
      final items = await csvDataService.listInboxItems();
      if (!mounted) return;
      setState(() {
        _inboxItems
          ..clear()
          ..addAll(items);
        statusMessage = 'File ${item.originalName} dihapus';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Gagal menghapus file: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          isCsvBusy = false;
        });
      }
    }
  }

  Widget _buildMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    String? subtitle,
  }) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionLine(String label, PermissionStatus? status) {
    return Text('• $label: ${_permissionLabel(status)}');
  }

  Widget _buildMeasurementTab(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(statusMessage),
                    const SizedBox(height: 12),
                    Text(
                      'Izin',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    _buildPermissionLine(
                      'Microphone',
                      permissionStatuses[Permission.microphone],
                    ),
                    _buildPermissionLine(
                      'Location',
                      permissionStatuses[Permission.location],
                    ),
                    _buildPermissionLine(
                      'Storage',
                      permissionStatuses[Permission.storage],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildMetricCard(
              title: 'Leq',
              value: '${currentLeq.toStringAsFixed(1)} dBA',
              icon: Icons.graphic_eq,
              color: Colors.teal,
              subtitle: 'Rata-rata energi dari sampel yang dikumpulkan',
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    title: 'Mean',
                    value: '${currentMeanDb.toStringAsFixed(1)} dB',
                    icon: Icons.hearing,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricCard(
                    title: 'Max',
                    value: '${currentMaxDb.toStringAsFixed(1)} dB',
                    icon: Icons.trending_up,
                    color: Colors.deepOrange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GPS & CSV',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      lastPosition == null
                          ? 'Longitude: -\nLatitude: -\nAltitude: -'
                          : 'Longitude: ${lastPosition!.longitude.toStringAsFixed(6)}\nLatitude: ${lastPosition!.latitude.toStringAsFixed(6)}\nAltitude: ${lastPosition!.altitude.toStringAsFixed(1)} m',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      lastSavedPath == null
                          ? 'Belum ada file CSV tersimpan'
                          : 'CSV terakhir: $lastSavedPath',
                    ),
                    const SizedBox(height: 8),
                    Text(
                      lastSavedTimestamp == null
                          ? 'Timestamp belum tersedia'
                          : 'Timestamp: $lastSavedTimestamp',
                    ),
                    const SizedBox(height: 8),
                    Text('Sampel tersimpan: ${samples.length}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _storageGranted
                  ? 'Storage permission: diizinkan'
                  : 'Storage permission: tidak wajib untuk app-specific directory',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCsvToolsTab(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _refreshInbox,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'CSV Tools',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(statusMessage),
                      const SizedBox(height: 12),
                      Text(
                        'CSV dari WhatsApp/open-with otomatis masuk ke inbox di aplikasi ini. Dari sini kamu bisa preview, hapus, lalu merge semuanya saat sudah yakin.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Inbox CSV (${_inboxItems.length})',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _refreshInbox,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lastSavedPath == null
                            ? 'CSV rolling: belum ada'
                            : 'CSV rolling: $lastSavedPath',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lastMergedPath == null
                            ? 'CSV gabungan: belum ada'
                            : 'CSV gabungan: $lastMergedPath',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lastMergedFileCount == null
                            ? 'Jumlah file saat merge: -'
                            : 'Jumlah file saat merge: $lastMergedFileCount',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (!_inboxLoaded)
                const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ))
              else if (_inboxItems.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Belum ada CSV masuk. Kirim file CSV dari WhatsApp ke aplikasi ini agar muncul di daftar.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _inboxItems.length,
                  separatorBuilder: (context, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = _inboxItems[index];
                    return Card(
                      child: ListTile(
                        onTap: () => _previewInboxItem(item),
                        title: Text(item.originalName),
                        subtitle: Text(
                          'Diproses: ${item.importedAt.toLocal()}\nUkuran: ${item.sizeBytes} bytes\n${item.preview}',
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        leading: const Icon(Icons.table_view),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.share),
                              onPressed: () => _shareFile(
                                item.file.path,
                                subject: 'File CSV: ${item.originalName}',
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteInboxItem(item),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 220,
                    child: ElevatedButton.icon(
                      onPressed: _canMerge ? _mergeAllCsvFiles : null,
                      icon: const Icon(Icons.merge_type),
                      label: const Text('Merge All CSV'),
                    ),
                  ),
                  if (lastMergedPath != null)
                    SizedBox(
                      width: 220,
                      child: OutlinedButton.icon(
                        onPressed: () => _shareFile(
                          lastMergedPath,
                          subject: 'Hasil Merge CSV - Noise Map Collector',
                        ),
                        icon: const Icon(Icons.share),
                        label: const Text('Share Merged CSV'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Tip: tap item untuk preview, ikon tempat sampah untuk hapus, lalu tekan Merge All CSV saat inbox sudah bersih dan siap digabung.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _buildMeasurementTab(context),
      _buildCsvToolsTab(context),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedTabIndex == 0 ? widget.title : 'CSV Tools'),
        actions: [
          if (_selectedTabIndex == 0)
            IconButton(
              icon: const Icon(Icons.security),
              tooltip: 'Refresh Izin',
              onPressed: requestPermissions,
            ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTabIndex,
        children: pages,
      ),
      floatingActionButton: _selectedTabIndex == 0
          ? FloatingActionButton.extended(
              onPressed: isMeasuring ? stopMeasurement : startMeasurement,
              label: Text(isMeasuring ? 'STOP & SAVE' : 'START'),
              icon: Icon(isMeasuring ? Icons.stop : Icons.play_arrow),
              backgroundColor: isMeasuring ? Colors.redAccent : Colors.teal,
              foregroundColor: Colors.white,
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTabIndex,
        onTap: (index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.hearing),
            label: 'Collector',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder_copy),
            label: 'CSV Tools',
          ),
        ],
      ),
    );
  }
}
