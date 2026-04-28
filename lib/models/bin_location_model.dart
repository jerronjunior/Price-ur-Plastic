/// Map-based bin location model for storing bin coordinates and names.
class BinLocationModel {
  BinLocationModel({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory BinLocationModel.fromMap(Map<String, dynamic> m) => BinLocationModel(
        id: (m['id'] ?? m['doc_id'] ?? '') as String,
        name: (m['name'] ?? '') as String,
        latitude: (m['latitude'] is num) ? (m['latitude'] as num).toDouble() : double.tryParse('${m['latitude']}') ?? 0.0,
        longitude: (m['longitude'] is num) ? (m['longitude'] as num).toDouble() : double.tryParse('${m['longitude']}') ?? 0.0,
      );

  @override
  String toString() => 'BinLocationModel($id, $name, $latitude, $longitude)';
}
