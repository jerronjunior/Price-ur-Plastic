import 'dart:io';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../../core/theme.dart';
import '../../models/bin_location_model.dart';
import '../../services/firestore_service.dart';
import 'bin_image_verification_screen.dart';

class _LocationSuggestion {
  const _LocationSuggestion({
    required this.displayName,
    required this.latitude,
    required this.longitude,
  });

  factory _LocationSuggestion.fromJson(Map<String, dynamic> json) {
    return _LocationSuggestion(
      displayName: (json['display_name'] ?? '').toString(),
      latitude: double.tryParse((json['lat'] ?? '').toString()) ?? 0.0,
      longitude: double.tryParse((json['lon'] ?? '').toString()) ?? 0.0,
    );
  }

  final String displayName;
  final double latitude;
  final double longitude;
}

class AddBinScreen extends StatefulWidget {
  const AddBinScreen({
    super.key,
    this.bin,
    this.scannedBinType,
  });

  final BinLocationModel? bin;
  final String? scannedBinType;

  @override
  State<AddBinScreen> createState() => _AddBinScreenState();
}

class _AddBinScreenState extends State<AddBinScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _search = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();

  final Set<Marker> _markers = {};
  final List<_LocationSuggestion> _searchResults = [];

  GoogleMapController? _mapController;
  LatLng? _selectedLatLng;
  bool _loading = false;
  bool _searching = false;
  String? _searchError;
  
  // Bin image verification
  XFile? _capturedBinImage;

  @override
  void initState() {
    super.initState();
    if (widget.bin != null) {
      _name.text = widget.bin!.name;
      _lat.text = widget.bin!.latitude.toString();
      _lng.text = widget.bin!.longitude.toString();
      _selectedLatLng = LatLng(widget.bin!.latitude, widget.bin!.longitude);
      _markers.add(
        Marker(
          markerId: const MarkerId('selected'),
          position: _selectedLatLng!,
          draggable: true,
          onDragEnd: _onMarkerMoved,
        ),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _search.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _startBinImageVerification() async {
    final result = await Navigator.of(context).push<XFile>(
      MaterialPageRoute(
        builder: (ctx) => BinImageVerificationScreen(
          onImageCaptured: (image) {
            Navigator.of(ctx).pop(image);
          },
          onBack: () => Navigator.of(ctx).pop(),
        ),
      ),
    );

    if (result != null && mounted) {
      setState(() => _capturedBinImage = result);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bin image captured successfully!'),
          backgroundColor: Color(0xFF4CAF50),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _clearBinImage() {
    setState(() => _capturedBinImage = null);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final latitude = double.tryParse(_lat.text.trim());
    final longitude = double.tryParse(_lng.text.trim());
    if (latitude == null || longitude == null) return;

    setState(() => _loading = true);
    try {
      final fs = FirestoreService();
      final id = widget.bin?.id ?? '';
      final bin = BinLocationModel(
        id: id,
        name: _name.text.trim(),
        latitude: latitude,
        longitude: longitude,
      );

      if (id.isEmpty) {
        await fs.addBinLocation(bin);
      } else {
        await fs.updateBinLocation(bin);
      }

      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _searchLocation() async {
    final query = _search.text.trim();
    if (query.isEmpty) {
      setState(() {
        _searchError = 'Type a location to search';
        _searchResults.clear();
      });
      return;
    }

    setState(() {
      _searching = true;
      _searchError = null;
      _searchResults.clear();
    });

    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/search',
        <String, String>{
          'q': query,
          'format': 'jsonv2',
          'limit': '5',
          'addressdetails': '1',
        },
      );

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent': 'Price-ur-Plastic/1.0',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode != 200) {
        throw Exception('Location search failed (${response.statusCode})');
      }

      final decoded = jsonDecode(response.body);
      final results = decoded is List
          ? decoded
              .whereType<Map>()
              .map(
                (item) => _LocationSuggestion.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((item) => item.displayName.isNotEmpty)
              .toList(growable: false)
          : const <_LocationSuggestion>[];

      if (!mounted) return;
      setState(() {
        _searchResults
          ..clear()
          ..addAll(results);
        _searchError = results.isEmpty ? 'No locations found' : null;
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = 'Unable to search location';
      });
    }
  }

  Future<void> _selectLocation(_LocationSuggestion location) async {
    final pos = LatLng(location.latitude, location.longitude);
    setState(() {
      _search.text = location.displayName;
      _searchResults.clear();
      _searchError = null;
    });

    _updateSelectedLocation(pos);
    await _mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
  }

  void _onMapTapped(LatLng pos) {
    _updateSelectedLocation(pos);
  }

  void _onMarkerMoved(LatLng pos) {
    _updateSelectedLocation(pos);
  }

  void _updateSelectedLocation(LatLng pos) {
    setState(() {
      _selectedLatLng = pos;
      _lat.text = pos.latitude.toStringAsFixed(6);
      _lng.text = pos.longitude.toStringAsFixed(6);
      _markers.removeWhere((marker) => marker.markerId.value == 'selected');
      _markers.add(
        Marker(
          markerId: const MarkerId('selected'),
          position: pos,
          draggable: true,
          onDragEnd: _onMarkerMoved,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.bin == null ? 'Add Bin' : 'Edit Bin')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Show scanned bin type if available
              if (widget.scannedBinType != null) ...[
                Card(
                  color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle,
                          color: Color(0xFF4CAF50),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Bin Scanned',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF4CAF50),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                widget.scannedBinType!,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Search location',
                  hintText: 'Type a place, road, or landmark',
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.search),
                          onPressed: _searchLocation,
                        ),
                ),
                onFieldSubmitted: (_) => _searchLocation(),
              ),
              if (_searchError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _searchError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              if (_searchResults.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.white,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: Colors.grey.shade200),
                    itemBuilder: (context, index) {
                      final result = _searchResults[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.place,
                          color: AppTheme.primaryGreen,
                        ),
                        title: Text(
                          result.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${result.latitude.toStringAsFixed(6)}, ${result.longitude.toStringAsFixed(6)}',
                        ),
                        onTap: () => _selectLocation(result),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                height: 250,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _selectedLatLng ?? const LatLng(0, 0),
                      zoom: _selectedLatLng == null ? 2 : 16,
                    ),
                    onMapCreated: (controller) {
                      _mapController = controller;
                    },
                    onTap: _onMapTapped,
                    markers: _markers,
                    myLocationEnabled: false,
                    zoomControlsEnabled: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Bin name'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter name'
                    : null,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _lat,
                      decoration: const InputDecoration(labelText: 'Latitude'),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) => (v == null || double.tryParse(v) == null)
                          ? 'Enter latitude'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lng,
                      decoration: const InputDecoration(labelText: 'Longitude'),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) => (v == null || double.tryParse(v) == null)
                          ? 'Enter longitude'
                          : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Bin Image Verification Section
              Card(
                color: _capturedBinImage != null
                    ? const Color(0xFF4CAF50).withValues(alpha: 0.1)
                    : Colors.grey.shade100,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _capturedBinImage != null
                                ? Icons.check_circle
                                : Icons.camera_alt,
                            color: _capturedBinImage != null
                                ? const Color(0xFF4CAF50)
                                : Colors.grey,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Bin Image Verification',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  _capturedBinImage != null
                                      ? 'Image captured'
                                      : 'Capture bin photo to verify',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_capturedBinImage != null) ...[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(
                            File(_capturedBinImage!.path),
                            height: 150,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.refresh),
                                label: const Text('Retake'),
                                onPressed: () => _startBinImageVerification(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.close),
                                label: const Text('Remove'),
                                onPressed: _clearBinImage,
                              ),
                            ),
                          ],
                        ),
                      ] else
                        ElevatedButton.icon(
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Capture Bin Image'),
                          onPressed: _startBinImageVerification,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryGreen,
                            foregroundColor: Colors.white,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _save,
                child: _loading
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
