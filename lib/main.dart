import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final NoiseMeter noiseMeter = NoiseMeter();
  StreamSubscription<NoiseReading>? subscription;
  final List<double> samples = [];

  Map<Permission, PermissionStatus> permissionStatuses = const {};

  double currentMeanDb = 0;
  double currentMaxDb = 0;
  double currentLeq = 0;
  bool isMeasuring = false;
  bool isSaving = false;
  String statusMessage = 'Siap mengumpulkan data';
  Position? lastPosition;
  String? lastSavedTimestamp;
  String? lastSavedPath;

  @override
  void initState() {
    super.initState();
    requestPermissions();
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
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

  bool get _canStart => _hasRequiredPermissions && !isMeasuring && !isSaving;

  bool get _canStop => isMeasuring && !isSaving;

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
    final directory = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final file = File(
      '${directory.path}${Platform.pathSeparator}noise_data.csv',
    );

    final position = await getLocation();
    final exists = await file.exists();
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final row =
        '$timestamp,${position.longitude},${position.latitude},${leq.toStringAsFixed(1)}\n';

    final sink = file.openWrite(mode: FileMode.append);
    if (!exists) {
      sink.writeln('timestamp_utc,longitude,latitude,noise_db');
    }
    sink.write(row);
    await sink.flush();
    await sink.close();

    if (mounted) {
      setState(() {
        lastPosition = position;
        lastSavedTimestamp = timestamp;
      });
    }

    return file.path;
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
    lastSavedPath = null;

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
            statusMessage = 'Mengambil sampel: ${samples.length} data';
          });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: SafeArea(
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
                            ? 'Posisi belum diambil'
                            : 'Longitude: ${lastPosition!.longitude.toStringAsFixed(6)}\nLatitude: ${lastPosition!.latitude.toStringAsFixed(6)}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        lastSavedPath == null
                            ? 'Belum ada file CSV tersimpan'
                            : 'CSV: $lastSavedPath',
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
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 180,
                    child: ElevatedButton.icon(
                      onPressed: _canStart ? startMeasurement : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start'),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: ElevatedButton.icon(
                      onPressed: _canStop ? stopMeasurement : null,
                      icon: isSaving
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.stop),
                      label: const Text('Stop & Save'),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: OutlinedButton.icon(
                      onPressed: requestPermissions,
                      icon: const Icon(Icons.security),
                      label: const Text('Refresh Izin'),
                    ),
                  ),
                ],
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
      ),
    );
  }
}
