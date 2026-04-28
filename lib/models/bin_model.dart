/// Recycling bin metadata (from QR scan + map location).
class BinModel {
  final String binId;
  final String qrCode;
  final String locationName;
  final double latitude;
  final double longitude;

  const BinModel({
    required this.binId,
    required this.qrCode,
    required this.locationName,
    this.latitude = 0.0,
    this.longitude = 0.0,
  });

  factory BinModel.fromMap(String id, Map<String, dynamic> map) {
    final resolvedBinId = (map['binId'] as String?)?.trim();
    final resolvedQr = (map['qrCode'] as String?)?.trim();
    return BinModel(
      binId: (resolvedBinId != null && resolvedBinId.isNotEmpty) ? resolvedBinId : id,
      qrCode: (resolvedQr != null && resolvedQr.isNotEmpty)
          ? resolvedQr
          : ((resolvedBinId != null && resolvedBinId.isNotEmpty) ? resolvedBinId : id),
      locationName: map['locationName'] as String? ?? 'Unknown',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toMap() => {
        'binId': binId,
        'qrCode': qrCode,
        'locationName': locationName,
        'latitude': latitude,
        'longitude': longitude,
      };
}
