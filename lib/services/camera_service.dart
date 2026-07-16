import 'package:camera/camera.dart';

/// Caches the platform's [availableCameras] result.
///
/// The scan flow opens/closes a CameraController several times in a row
/// (bin scan → bottle scan → insertion check), and each of those screens
/// used to call `availableCameras()` fresh on every open — an extra
/// platform-channel round trip (tens of ms) added to every camera-open
/// on top of the actual hardware open time. The camera list can't change
/// mid-session, so fetch it once and reuse it everywhere.
class CameraService {
  CameraService._();

  static List<CameraDescription>? _cached;
  static Future<List<CameraDescription>>? _inFlight;

  static Future<List<CameraDescription>> getCameras() {
    final cached = _cached;
    if (cached != null) return Future.value(cached);
    return _inFlight ??= availableCameras().then((cams) {
      _cached = cams;
      _inFlight = null;
      return cams;
    }, onError: (Object e) {
      _inFlight = null;
      throw e;
    });
  }

  static Future<CameraDescription?> getBackCamera() async {
    final cams = await getCameras();
    if (cams.isEmpty) return null;
    return cams.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cams.first,
    );
  }
}
