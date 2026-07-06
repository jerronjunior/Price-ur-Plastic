/// SMS gateway wrapper removed; this app no longer depends on external SMS calls.
class SmsService {
  Future<bool> sendOtp({
    required String phone,
    String? otp,
  }) async {
    return false;
  }

  Future<bool> verifyOtp({
    required String phone,
    required String otp,
  }) async {
    return false;
  }

  Future<bool> sendBottleCount({
    required String phone,
    required int bottleCount,
    required int totalPoints,
  }) async {
    return false;
  }
}
