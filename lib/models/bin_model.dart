/// Recycling bin metadata (from QR scan).
class BinModel {
  final String binId;
  final String locationName;

  const BinModel({
    required this.binId,
    required this.locationName,
  });

  factory BinModel.fromMap(String id, Map<String, dynamic> map) {
    return BinModel(
      binId: id,
      locationName: map['locationName'] as String? ?? 'Unknown',
    );
  }

  Map<String, dynamic> toMap() => {
        'locationName': locationName,
      };
}
