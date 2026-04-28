import 'package:location/location.dart';

class LocationService {
  final Location _loc = Location();

  Future<bool> requestPermission() async {
    final enabled = await _loc.serviceEnabled();
    if (!enabled) {
      final en = await _loc.requestService();
      if (!en) return false;
    }

    var perm = await _loc.hasPermission();
    if (perm == PermissionStatus.denied) {
      perm = await _loc.requestPermission();
      if (perm != PermissionStatus.granted) return false;
    }
    return true;
  }

  Future<LocationData?> getCurrentLocation() async {
    try {
      final ok = await requestPermission();
      if (!ok) return null;
      return await _loc.getLocation();
    } catch (_) {
      return null;
    }
  }

  Stream<LocationData> onLocationChanged() => _loc.onLocationChanged;
}
