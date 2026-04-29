import 'package:cloud_functions/cloud_functions.dart';

/// Thin wrapper around Firebase Cloud Functions for SMS actions.
class SmsService {
  SmsService({FirebaseFunctions? functions})
  : _functions = functions ?? FirebaseFunctions.instanceFor(region: 'us-central1');

  final FirebaseFunctions _functions;

  Future<bool> sendOtp({
    required String phone,
    String? otp,
  }) async {
    final callable = _functions.httpsCallable('sendOtp');
    final result = await callable.call(<String, dynamic>{
      'phone': phone,
      if (otp != null && otp.trim().isNotEmpty) 'otp': otp.trim(),
    });

    final data = result.data;
    if (data is Map) {
      return data['success'] == true;
    }
    return data == true;
  }

  Future<bool> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    final callable = _functions.httpsCallable('verifyOtp');
    final result = await callable.call(<String, dynamic>{
      'phone': phone,
      'otp': otp,
    });

    final data = result.data;
    if (data is Map) {
      return data['success'] == true;
    }
    return data == true;
  }

  Future<bool> sendBottleCount({
    required String phone,
    required int bottleCount,
    required int totalPoints,
  }) async {
    final callable = _functions.httpsCallable('sendBottleCount');
    final result = await callable.call(<String, dynamic>{
      'phone': phone,
      'bottleCount': bottleCount,
      'totalPoints': totalPoints,
    });

    final data = result.data;
    if (data is Map) {
      return data['success'] == true;
    }
    return data == true;
  }
}