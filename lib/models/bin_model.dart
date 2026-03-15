/// Recycling bin metadata (from QR scan).
class BinModel {
  final String binId;
  final String qrCode;
  final String locationName;

  const BinModel({
    required this.binId,
    required this.qrCode,
    required this.locationName,
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
    );
  }

  Map<String, dynamic> toMap() => {
        'binId': binId,
        'qrCode': qrCode,
        'locationName': locationName,
      };
}
