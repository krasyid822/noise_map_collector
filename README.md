# noise_map_collector

Aplikasi untuk mengumpulkan titik kebisingan (db meter) dan koordinat

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Copilot Instructions

- Request Permission di Flutter
  Panggil ini di initState().
  Future<void> requestPermissions() async {
  await [
  Permission.microphone,
  Permission.location,
  Permission.storage,
  ].request();
  }
- Core: Mengukur Kebisingan (dBA Estimasi)
* inisiasi noise meter
  final NoiseMeter noiseMeter = NoiseMeter();
  StreamSubscription<NoiseReading>? subscription;
* mulai pengukuran
  void startMeasurement() {
  subscription = noiseMeter.noiseStream.listen((reading) {
  double leq = reading.meanDecibel;
  double max = reading.maxDecibel;

  print("Leq: $leq dB | Max: $max dB");
  });
  }
* stop
  void stopMeasurement() {
  subscription?.cancel();
  }
- Hitung Leq Manual (Lebih Akurat)
  List<double> samples = [];

void addSample(double db) {
samples.add(db);
}

double calculateLeq() {
double sum = 0;
for (var db in samples) {
sum += pow(10, db / 10);
}
return 10 * log(sum / samples.length) / ln10;
}
- Ambil Koordinat GPS
  Future<Position> getLocation() async {
  return await Geolocator.getCurrentPosition(
  desiredAccuracy: LocationAccuracy.high);
  }
- Simpan Data (CSV untuk QGIS)
  Future<void> saveCSV(double leq) async {
  final dir = await getExternalStorageDirectory();
  final file = File("${dir!.path}/noise_data.csv");

  final pos = await getLocation();

  String row =
  "${DateTime.now().toUtc().toIso8601String()},${pos.longitude},${pos.latitude},${leq.toStringAsFixed(1)}\n";

  await file.writeAsString(row, mode: FileMode.append);
  }
* output csv
  timestamp_utc,longitude,latitude,noise_db
  2026-04-24T12:34:56.000Z,98.6735,3.5952,72.4
- UI Minimal (Contoh)
  Column(
  children: [
  Text("Leq: ${leq.toStringAsFixed(1)} dBA",
  style: TextStyle(fontSize: 32)),
  ElevatedButton(
  onPressed: startMeasurement,
  child: Text("Start"),
  ),
  ElevatedButton(
  onPressed: stopMeasurement,
  child: Text("Stop & Save"),
  ),
  ],
  );