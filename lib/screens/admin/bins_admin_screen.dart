import 'package:flutter/material.dart';
import '../../models/bin_location_model.dart';
import '../../services/firestore_service.dart';
import 'add_bin_screen.dart';

class BinsAdminScreen extends StatefulWidget {
  const BinsAdminScreen({super.key});

  @override
  State<BinsAdminScreen> createState() => _BinsAdminScreenState();
}

class _BinsAdminScreenState extends State<BinsAdminScreen> {
  late final FirestoreService _fs;
  List<BinLocationModel> _bins = [];

  @override
  void initState() {
    super.initState();
    _fs = FirestoreService();
    _load();
  }

  Future<void> _load() async {
    final bins = await _fs.getBinLocations();
    setState(() => _bins = bins);
  }

  Future<void> _delete(String id) async {
    await _fs.deleteBinLocation(id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Bins')),
      body: ListView.builder(
        itemCount: _bins.length,
        itemBuilder: (_, i) {
          final b = _bins[i];
          return ListTile(
            title: Text(b.name),
            subtitle: Text('${b.latitude}, ${b.longitude}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _delete(b.id),
            ),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddBinScreen(bin: b)));
              await _load();
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddBinScreen()));
          await _load();
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
