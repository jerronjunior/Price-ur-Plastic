import 'dart:async';
import 'dart:math' show cos, sqrt, atan2, sin, pi;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/bin_model.dart';
import '../../services/firestore_service.dart';
import '../../services/location_service.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final Completer<GoogleMapController> _controller = Completer();
  final Set<Marker> _markers = {};
  final Set<Polyline> _polylines = {};
  LatLng? _userLatLng;
  List<BinModel> _bins = [];
  StreamSubscription<List<BinModel>>? _binsSubscription;
  LatLng? _pendingCameraTarget;
  bool _hasCenteredMap = false;
  final Stopwatch _startupTimer = Stopwatch();

  @override
  void initState() {
    super.initState();
    _startupTimer.start();

    final cached = LocationService().getCachedLocation();
    if (cached != null && cached.latitude != null && cached.longitude != null) {
      _userLatLng = LatLng(cached.latitude!, cached.longitude!);
      _markers.add(Marker(
        markerId: const MarkerId('user'),
        position: _userLatLng!,
        infoWindow: const InfoWindow(title: 'You are here'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ));
    }

    _subscribeToBins();
    _startBackgroundInit();
  }

  void _subscribeToBins() {
    final fs = Provider.of<FirestoreService>(context, listen: false);
    _binsSubscription ??= fs.getAllBinsStream().listen((bins) {
      if (!mounted) return;
      setState(() {
        _bins = bins;
        _updateBinMarkers();
      });

      debugPrint('Map init: bins received (${bins.length}) after ${_startupTimer.elapsedMilliseconds} ms');

      if (!_hasCenteredMap) {
        if (_userLatLng != null) {
          _centerMapOn(_userLatLng!);
        } else if (_bins.isNotEmpty) {
          _centerMapOn(LatLng(_bins.first.latitude, _bins.first.longitude));
        }
      }
    }, onError: (e) {
      debugPrint('Map init: bins stream error: $e');
    });
  }

  void _startBackgroundInit() {
    unawaited(_backgroundInit());
  }

  Future<void> _backgroundInit() async {
    final locService = LocationService();

    try {
      final loc = await locService.getCurrentLocation();
      if (loc != null && mounted && loc.latitude != null && loc.longitude != null) {
        _updateUserLocation(LatLng(loc.latitude!, loc.longitude!));
        debugPrint('Map init: got current location after ${_startupTimer.elapsedMilliseconds} ms');
      }
    } catch (e) {
      debugPrint('Map init: failed to get current location: $e');
    }

    debugPrint('Map init: background init completed at ${_startupTimer.elapsedMilliseconds} ms');
  }

  void _updateUserLocation(LatLng pos) {
    setState(() {
      _userLatLng = pos;
      _markers.removeWhere((m) => m.markerId.value == 'user');
      _markers.add(Marker(
        markerId: const MarkerId('user'),
        position: pos,
        infoWindow: const InfoWindow(title: 'You are here'),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ));
    });

    _centerMapOn(pos);
  }

  Future<void> _centerMapOn(LatLng target) async {
    _pendingCameraTarget = target;
    if (!_controller.isCompleted) return;

    final controller = await _controller.future;
    if (!mounted) return;

    _hasCenteredMap = true;
    _pendingCameraTarget = null;
    await controller.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: 15),
      ),
    );
  }

  void _updateBinMarkers() {
    _markers.removeWhere((m) => m.markerId.value.startsWith('bin_'));
    for (final b in _bins) {
      _markers.add(Marker(
        markerId: MarkerId('bin_${b.binId}'),
        position: LatLng(b.latitude, b.longitude),
        infoWindow: InfoWindow(title: b.locationName),
        onTap: () => _onBinTapped(b),
      ));
    }
  }

  void _onBinTapped(BinModel bin) {
    _showBinBottomSheet(bin);
  }

  void _showBinBottomSheet(BinModel bin) {
    final dist = _userLatLng == null
        ? null
        : _distanceMeters(_userLatLng!, LatLng(bin.latitude, bin.longitude));
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(bin.locationName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (dist != null) Text('${(dist / 1000).toStringAsFixed(2)} km away'),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _getDirectionsTo(bin);
                  },
                  child: const Text('Get Directions'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('Close'),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const earth = 6371000;
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);
    final h = (sin(dLat / 2) * sin(dLat / 2)) + cos(lat1) * cos(lat2) * (sin(dLon / 2) * sin(dLon / 2));
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return earth * c;
  }

  double _deg2rad(double deg) => deg * (pi / 180);

  Future<List<BinModel>> _loadBinsForNearest() async {
    if (_bins.isNotEmpty) return List<BinModel>.from(_bins);

    final fs = Provider.of<FirestoreService>(context, listen: false);
    try {
      final bins = await fs.getAllBinsStream().first;
      if (!mounted) return const [];
      setState(() {
        _bins = bins;
        _updateBinMarkers();
      });
      return bins;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _findNearest() async {
    final userLocation = _userLatLng;
    if (userLocation == null) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(content: Text('Current location is not available yet.')),
      );
      return;
    }

    final bins = await _loadBinsForNearest();
    final usableBins = bins.where((b) => b.latitude != 0.0 || b.longitude != 0.0).toList(growable: false);

    if (usableBins.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No bin locations are available yet.')),
        );
      }
      return;
    }

    BinModel? nearest;
    double best = double.infinity;
    for (final b in usableBins) {
      final d = _distanceMeters(userLocation, LatLng(b.latitude, b.longitude));
      if (d < best) {
        best = d;
        nearest = b;
      }
    }

    if (nearest == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to determine the nearest bin.')),
        );
      }
      return;
    }

    final c = await _controller.future;
    final target = LatLng(nearest.latitude, nearest.longitude);
    await c.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 16)));
    if (!mounted) return;
    _onBinTapped(nearest);
  }

  Future<void> _getDirectionsTo(BinModel bin) async {
    if (_userLatLng == null) return;
    final origin = '${_userLatLng!.latitude},${_userLatLng!.longitude}';
    final dest = '${bin.latitude},${bin.longitude}';
    final url = Uri.https(
      'www.google.com',
      '/maps/dir/',
      {
        'api': '1',
        'origin': origin,
        'destination': dest,
        'travelmode': 'driving',
      },
    );

    final launched = await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
    );

    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to open directions.')),
      );
    }
  }

  @override
  void dispose() {
    _binsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Explore Locations')),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: _userLatLng ?? const LatLng(0, 0), zoom: 14),
        myLocationEnabled: _userLatLng != null,
        markers: _markers,
        polylines: _polylines,
        onMapCreated: (g) {
          debugPrint('Map widget created after ${_startupTimer.elapsedMilliseconds} ms');
          if (!_controller.isCompleted) {
            _controller.complete(g);
          }

          if (_pendingCameraTarget != null) {
            _centerMapOn(_pendingCameraTarget!);
          } else if (_userLatLng != null) {
            _centerMapOn(_userLatLng!);
          } else if (_bins.isNotEmpty) {
            _centerMapOn(LatLng(_bins.first.latitude, _bins.first.longitude));
          }
        },
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            onPressed: _findNearest,
            label: const Text('Find Nearest Bin'),
            icon: const Icon(Icons.location_searching),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'loc',
            onPressed: () async {
              final l = await LocationService().getCurrentLocation();
              if (l != null && l.latitude != null && l.longitude != null) {
                final pos = LatLng(l.latitude!, l.longitude!);
                _updateUserLocation(pos);
              }
            },
            child: const Icon(Icons.my_location),
          ),
        ],
      ),
    );
  }
}