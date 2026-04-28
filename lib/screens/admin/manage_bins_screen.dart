import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:location/location.dart';
import 'package:http/http.dart' as http;
import '../../services/firestore_service.dart';
import '../../models/bin_model.dart';
import '../../core/theme.dart';

const String _googleMapsApiKey = 'AIzaSyCBmI_4GT9sOei5WWA8j-7XGnAI5yievmY';

/// Admin screen to manage recycling bins.
class ManageBinsScreen extends StatefulWidget {
  const ManageBinsScreen({super.key});

  @override
  State<ManageBinsScreen> createState() => _ManageBinsScreenState();
}

class _ManageBinsScreenState extends State<ManageBinsScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  static bool get _isDesktopPlatform =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  void _showAddOptionsSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.qr_code_scanner),
                  title: const Text('Scan QR and Add Bin'),
                  subtitle: const Text('Scan a bin QR code, then save location'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openScanAndAddFlow();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Add Bin Manually'),
                  subtitle: const Text('Type QR value and location manually'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showAddBinDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openScanAndAddFlow() async {
    final scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: _isDesktopPlatform ? CameraFacing.front : CameraFacing.back,
      torchEnabled: false,
    );

    bool attemptedDesktopFallback = false;
    bool fallbackInProgress = false;

    final scannedValue = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        bool detected = false;
        return SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.8,
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Scan Bin QR',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: MobileScanner(
                  controller: scannerController,
                  onDetect: (capture) {
                    if (detected || capture.barcodes.isEmpty) return;
                    final value = capture.barcodes.first.rawValue?.trim();
                    if (value == null || value.isEmpty) return;
                    detected = true;
                    Navigator.pop(sheetContext, value);
                  },
                  errorBuilder: (context, error, child) {
                    if (_isDesktopPlatform &&
                        !attemptedDesktopFallback &&
                        !fallbackInProgress) {
                      fallbackInProgress = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) async {
                        try {
                          await scannerController.switchCamera();
                        } catch (_) {
                          // Let the error message guide the user.
                        } finally {
                          attemptedDesktopFallback = true;
                          fallbackInProgress = false;
                        }
                      });
                    }

                    return Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: const Text(
                        'Camera unavailable. We auto-tried another camera once.\nIf it is still black, close other camera apps and reopen this scanner.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );

    scannerController.dispose();

    if (!mounted || scannedValue == null || scannedValue.isEmpty) return;
    _showAddBinDialog(prefilledQrValue: scannedValue);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Bins'),
      ),
      body: StreamBuilder<List<BinModel>>(
        stream: _firestoreService.getAllBinsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final bins = snapshot.data ?? [];

          if (bins.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.delete_outline,
                    size: 80,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No bins added yet',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap the + button to add your first bin',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: bins.length,
            itemBuilder: (context, index) {
              final bin = bins[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  isThreeLine: true,
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.qr_code,
                      color: AppTheme.primaryGreen,
                    ),
                  ),
                  title: Text(
                    bin.locationName,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    'Bin ID: ${bin.binId}\nQR: ${bin.qrCode}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, color: AppTheme.primaryBlue),
                        onPressed: () => _showEditBinDialog(bin),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: AppTheme.error),
                        onPressed: () => _confirmDeleteBin(bin),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddOptionsSheet,
        backgroundColor: AppTheme.primaryGreen,
        icon: const Icon(Icons.add),
        label: const Text('Add Bin'),
      ),
    );
  }

  void _showAddBinDialog({String? prefilledQrValue}) {
    final binIdController = TextEditingController(text: prefilledQrValue ?? '');
    final locationController = TextEditingController();
    LatLng? selectedLocation;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add New Bin'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: binIdController,
                decoration: const InputDecoration(
                  labelText: 'QR Code Value',
                  hintText: 'e.g., BIN001 or full QR text',
                  prefixIcon: Icon(Icons.qr_code),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: locationController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Location Name',
                  hintText: 'Select from map',
                  prefixIcon: Icon(Icons.location_on),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final picked = await _pickLocationFromMap();
                    if (picked == null) return;
                    final name = await _reverseGeocode(picked);
                    if (!dialogContext.mounted) return;
                    selectedLocation = picked;
                    locationController.text = name;
                    (dialogContext as Element).markNeedsBuild();
                  },
                  icon: const Icon(Icons.map),
                  label: const Text('Select location from map'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final binId = binIdController.text.trim();
              final location = locationController.text.trim();

              if (binId.isEmpty || location.isEmpty || selectedLocation == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter QR and pick a location from the map')),
                );
                return;
              }

              try {
                await _firestoreService.addBin(
                  binId,
                  location,
                  latitude: selectedLocation!.latitude,
                  longitude: selectedLocation!.longitude,
                );
                if (context.mounted) {
                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Bin, QR, and location saved successfully'),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error adding bin: $e')),
                  );
                }
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showEditBinDialog(BinModel bin) {
    final locationController = TextEditingController(text: bin.locationName);
    LatLng? selectedLocation;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit Bin'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                enabled: false,
                decoration: InputDecoration(
                  labelText: 'Bin ID',
                  hintText: bin.binId,
                  prefixIcon: const Icon(Icons.qr_code),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: locationController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Location Name',
                  hintText: 'Select from map',
                  prefixIcon: Icon(Icons.location_on),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final picked = await _pickLocationFromMap();
                    if (picked == null) return;
                    final name = await _reverseGeocode(picked);
                    if (!dialogContext.mounted) return;
                    selectedLocation = picked;
                    locationController.text = name;
                    (dialogContext as Element).markNeedsBuild();
                  },
                  icon: const Icon(Icons.map),
                  label: const Text('Select location from map'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final location = locationController.text.trim();

              if (location.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Location cannot be empty')),
                );
                return;
              }

              try {
                await _firestoreService.updateBin(
                  bin.binId,
                  location,
                  latitude: selectedLocation?.latitude,
                  longitude: selectedLocation?.longitude,
                );
                if (context.mounted) {
                  Navigator.pop(dialogContext);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Bin updated successfully')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error updating bin: $e')),
                  );
                }
              }
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  Future<LatLng?> _pickLocationFromMap() async {
    final location = Location();
    LatLng initial = const LatLng(0, 0);

    try {
      final enabled = await location.serviceEnabled() || await location.requestService();
      if (enabled) {
        final permission = await location.hasPermission();
        final granted = permission == PermissionStatus.granted ||
            permission == PermissionStatus.grantedLimited ||
            (permission == PermissionStatus.denied &&
                await location.requestPermission() == PermissionStatus.granted);
        if (granted) {
          final current = await location.getLocation();
          if (current.latitude != null && current.longitude != null) {
            initial = LatLng(current.latitude!, current.longitude!);
          }
        }
      }
    } catch (_) {
      // Use fallback initial position.
    }

    LatLng selected = initial;

    return showDialog<LatLng>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final markers = <Marker>{
              Marker(
                markerId: const MarkerId('selected'),
                position: selected,
                draggable: true,
                onDragEnd: (pos) => setLocalState(() => selected = pos),
              ),
            };

            return AlertDialog(
              title: const Text('Pick Location'),
              content: SizedBox(
                width: double.maxFinite,
                height: 420,
                child: GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: selected,
                    zoom: initial == const LatLng(0, 0) ? 2 : 16,
                  ),
                  markers: markers,
                  onTap: (pos) => setLocalState(() => selected = pos),
                  zoomControlsEnabled: true,
                  myLocationButtonEnabled: true,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, selected),
                  child: const Text('Use location'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<String> _reverseGeocode(LatLng position) async {
    try {
      final uri = Uri.parse(
        'https://maps.googleapis.com/maps/api/geocode/json?latlng=${position.latitude},${position.longitude}&key=$_googleMapsApiKey',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final results = data['results'] as List<dynamic>?;
        if (results != null && results.isNotEmpty) {
          final formatted = results.first['formatted_address'] as String?;
          if (formatted != null && formatted.trim().isNotEmpty) {
            return formatted;
          }
        }
      }
    } catch (_) {
      // fall through to coordinate-based label
    }

    return 'Selected location (${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)})';
  }

  void _confirmDeleteBin(BinModel bin) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Bin'),
        content: Text(
          'Are you sure you want to delete "${bin.locationName}"?\n\nBin ID: ${bin.binId}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
            ),
            onPressed: () async {
              try {
                await _firestoreService.deleteBin(bin.binId);
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Bin deleted successfully')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error deleting bin: $e')),
                  );
                }
              }
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
