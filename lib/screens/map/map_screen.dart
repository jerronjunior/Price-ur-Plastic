import 'dart:async';
import 'dart:math' show cos, sqrt, pow, atan2, sin, pi;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:location/location.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../../models/bin_location_model.dart';
import '../../services/firestore_service.dart';
import '../../services/location_service.dart';

// Google Directions API key (used for route polylines).
const String kGoogleMapsApiKey = 'AIzaSyCBmI_4GT9sOei5WWA8j-7XGnAI5yievmY';

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
  List<BinLocationModel> _bins = [];
  BinLocationModel? _selectedBin;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final locService = LocationService();
    final ok = await locService.requestPermission();
    if (!ok) return;

    final loc = await locService.getCurrentLocation();
    if (loc != null) {
      _updateUserLocation(LatLng(loc.latitude!, loc.longitude!));
    }

    final fs = Provider.of<FirestoreService>(context, listen: false);
    fs.binLocationsStream().listen((bins) {
      setState(() {
        _bins = bins;
        _updateBinMarkers();
      });
    });
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
  }

  void _updateBinMarkers() {
    _markers.removeWhere((m) => m.markerId.value.startsWith('bin_'));
    for (final b in _bins) {
      _markers.add(Marker(
        markerId: MarkerId('bin_${b.id}'),
        position: LatLng(b.latitude, b.longitude),
        infoWindow: InfoWindow(title: b.name),
        onTap: () => _onBinTapped(b),
      ));
    }
  }

  void _onBinTapped(BinLocationModel bin) {
    setState(() => _selectedBin = bin);
    _showBinBottomSheet(bin);
  }

  void _showBinBottomSheet(BinLocationModel bin) {
    final dist = _userLatLng == null ? null : _distanceMeters(_userLatLng!, LatLng(bin.latitude, bin.longitude));
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(bin.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (dist != null) Text('${(dist/1000).toStringAsFixed(2)} km away'),
            const SizedBox(height: 12),
            Row(children: [
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
            ])
          ],
        ),
      ),
    );
  }

  double _distanceMeters(LatLng a, LatLng b) {
    const earth = 6371000; // meters
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);
    final h = (sin(dLat/2) * sin(dLat/2)) + cos(lat1) * cos(lat2) * (sin(dLon/2) * sin(dLon/2));
    final c = 2 * atan2(sqrt(h), sqrt(1-h));
    return earth * c;
  }

  double _deg2rad(double deg) => deg * (pi / 180);

  Future<void> _findNearest() async {
    if (_userLatLng == null || _bins.isEmpty) return;
    BinLocationModel? nearest;
    double best = double.infinity;
    for (final b in _bins) {
      final d = _distanceMeters(_userLatLng!, LatLng(b.latitude, b.longitude));
      if (d < best) {
        best = d;
        nearest = b;
      }
    }
    if (nearest != null) {
      final c = await _controller.future;
      c.animateCamera(CameraUpdate.newLatLng(LatLng(nearest.latitude, nearest.longitude)));
      _onBinTapped(nearest);
    }
  }

  Future<void> _getDirectionsTo(BinLocationModel bin) async {
    if (_userLatLng == null) return;
    if (kGoogleMapsApiKey == 'YOUR_GOOGLE_DIRECTIONS_API_KEY') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Set Google Directions API key in code.')));
      return;
    }
    final origin = '${_userLatLng!.latitude},${_userLatLng!.longitude}';
    final dest = '${bin.latitude},${bin.longitude}';
    final url = Uri.parse('https://maps.googleapis.com/maps/api/directions/json?origin=$origin&destination=$dest&key=$kGoogleMapsApiKey');
    final resp = await http.get(url);
    if (resp.statusCode != 200) return;
    final data = json.decode(resp.body) as Map<String, dynamic>;
    if ((data['routes'] as List).isEmpty) return;
    final points = data['routes'][0]['overview_polyline']['points'] as String;
    final decoded = _decodePolyline(points);
    final poly = Polyline(
      polylineId: const PolylineId('route'),
      points: decoded,
      color: Colors.blue,
      width: 5,
    );
    setState(() {
      _polylines.clear();
      _polylines.add(poly);
    });
  }

  List<LatLng> _decodePolyline(String encoded) {
    final List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;
      final p = LatLng(lat / 1E5, lng / 1E5);
      poly.add(p);
    }
    return poly;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Explore Locations')),
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: _userLatLng ?? const LatLng(0,0), zoom: 14),
        myLocationEnabled: false,
        markers: _markers,
        polylines: _polylines,
        onMapCreated: (g) => _controller.complete(g),
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
              if (l != null) {
                final pos = LatLng(l.latitude!, l.longitude!);
                final c = await _controller.future;
                c.animateCamera(CameraUpdate.newLatLng(pos));
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
