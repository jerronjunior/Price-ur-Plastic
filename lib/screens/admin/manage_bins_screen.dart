import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/bin_location_model.dart';
import '../../models/bin_model.dart';
import '../../services/firestore_service.dart';
import 'add_bin_screen.dart';

/// Admin screen to manage recycling bins using map-based add/edit.
class ManageBinsScreen extends StatefulWidget {
  const ManageBinsScreen({super.key});

  @override
  State<ManageBinsScreen> createState() => _ManageBinsScreenState();
}

class _ManageBinsScreenState extends State<ManageBinsScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  Future<void> _openBinForm({BinModel? bin}) async {
    final binLocation = bin == null
        ? null
        : BinLocationModel(
            id: bin.binId,
            name: bin.locationName,
            latitude: bin.latitude,
            longitude: bin.longitude,
          );

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddBinScreen(bin: binLocation),
      ),
    );
  }

  Future<void> _confirmDeleteBin(BinModel bin) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Bin'),
        content: Text('Are you sure you want to delete "${bin.locationName}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (shouldDelete != true) return;

    try {
      await _firestoreService.deleteBinLocation(bin.binId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bin deleted successfully')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting bin: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Bins')),
      body: StreamBuilder<List<BinModel>>(
        stream: _firestoreService.getAllBinsStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final bins = snapshot.data ?? const <BinModel>[];

          if (bins.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.location_off,
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
                    'Tap the + button to add your first bin location',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                    textAlign: TextAlign.center,
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
                      color: AppTheme.primaryGreen.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.place,
                      color: AppTheme.primaryGreen,
                    ),
                  ),
                  title: Text(
                    bin.locationName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    'Bin ID: ${bin.binId}\n${bin.latitude.toStringAsFixed(6)}, ${bin.longitude.toStringAsFixed(6)}',
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
                        onPressed: () => _openBinForm(bin: bin),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: AppTheme.error),
                        onPressed: () => _confirmDeleteBin(bin),
                      ),
                    ],
                  ),
                  onTap: () => _openBinForm(bin: bin),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openBinForm(),
        backgroundColor: AppTheme.primaryGreen,
        icon: const Icon(Icons.add_location_alt),
        label: const Text('Add Bin Location'),
      ),
    );
  }
}
