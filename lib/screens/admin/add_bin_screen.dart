import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../models/bin_location_model.dart';
import '../../services/firestore_service.dart';

class AddBinScreen extends StatefulWidget {
  const AddBinScreen({super.key, this.bin});

  final BinLocationModel? bin;

  @override
  State<AddBinScreen> createState() => _AddBinScreenState();
}

class _AddBinScreenState extends State<AddBinScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  bool _loading = false;
  LatLng? _selectedLatLng;
  final Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    if (widget.bin != null) {
      _name.text = widget.bin!.name;
      _lat.text = widget.bin!.latitude.toString();
      _lng.text = widget.bin!.longitude.toString();
      _selectedLatLng = LatLng(widget.bin!.latitude, widget.bin!.longitude);
      _markers.add(Marker(
        markerId: const MarkerId('selected'),
        position: _selectedLatLng!,
        draggable: true,
        onDragEnd: (p) => _onMarkerMoved(p),
      ));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _loading = true);
    final fs = FirestoreService();
    final id = widget.bin?.id ?? '';
    final bin = BinLocationModel(
      id: id,
      name: _name.text.trim(),
      latitude: double.parse(_lat.text.trim()),
      longitude: double.parse(_lng.text.trim()),
    );
    if (id.isEmpty) {
      await fs.addBinLocation(bin);
    } else {
      await fs.updateBinLocation(bin);
    }
    if (!mounted) return;
    setState(() => _loading = false);
    Navigator.of(context).pop();
  }

  void _onMapTapped(LatLng pos) {
    setState(() {
      _selectedLatLng = pos;
      _lat.text = pos.latitude.toStringAsFixed(6);
      _lng.text = pos.longitude.toStringAsFixed(6);
      _markers.removeWhere((m) => m.markerId.value == 'selected');
      _markers.add(Marker(
        markerId: const MarkerId('selected'),
        position: pos,
        draggable: true,
        onDragEnd: (p) => _onMarkerMoved(p),
      ));
    });
  }

  void _onMarkerMoved(LatLng pos) {
    setState(() {
      _selectedLatLng = pos;
      _lat.text = pos.latitude.toStringAsFixed(6);
      _lng.text = pos.longitude.toStringAsFixed(6);
      _markers.removeWhere((m) => m.markerId.value == 'selected');
      _markers.add(Marker(
        markerId: const MarkerId('selected'),
        position: pos,
        draggable: true,
        onDragEnd: (p) => _onMarkerMoved(p),
      ));
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
              SizedBox(
                height: 250,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _selectedLatLng ?? const LatLng(0, 0),
                      zoom: _selectedLatLng == null ? 2 : 16,
                    ),
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
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter name' : null,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _lat,
                      decoration: const InputDecoration(labelText: 'Latitude'),
                      keyboardType: TextInputType.numberWithOptions(decimal: true),
                      validator: (v) => (v == null || double.tryParse(v) == null) ? 'Enter latitude' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _lng,
                      decoration: const InputDecoration(labelText: 'Longitude'),
                      keyboardType: TextInputType.numberWithOptions(decimal: true),
                      validator: (v) => (v == null || double.tryParse(v) == null) ? 'Enter longitude' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _save,
                child: _loading ? const SizedBox(height:24,width:24,child:CircularProgressIndicator(strokeWidth:2)) : const Text('Save'),
              )
            ],
          ),
        ),
      ),
    );
  }
}
