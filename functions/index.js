const admin = require('firebase-admin');
const functions = require('firebase-functions');

admin.initializeApp();

const db = admin.firestore();
const OTP_COLLECTION = 'otp_codes';
const TEXTLK_ENDPOINT = 'https://app.text.lk/api/v3/sms/send';

function getConfigValue(key, fallback = '') {
  return process.env[key] || fallback;
}

function normalizeSriLankaPhone(phone) {
  const digits = String(phone || '').replace(/\D/g, '');

  if (!digits) {
    throw new functions.https.HttpsError('invalid-argument', 'Phone number is required.');
  }

  if (digits.startsWith('94')) {
    return digits;
  }

  if (digits.startsWith('0') && digits.length >= 10) {
    return `94${digits.slice(1)}`;
  }

  if (digits.length === 9) {
    return `94${digits}`;
  }

  return digits;
}

function generateOtp() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

async function sendTextlkSms({ recipient, message }) {
  const config = functions.config();
  const token =
    config.textlk?.api_token ||
    config.textlk?.api_key ||
    getConfigValue('TEXTLK_API_TOKEN', getConfigValue('TEXTLK_API_KEY'));
  const senderId =
    config.textlk?.sender_id || getConfigValue('TEXTLK_SENDER_ID', 'TextLKDemo');

  if (!token) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'Missing text.lk API token. Set TEXTLK_API_TOKEN or TEXTLK_API_KEY in the Cloud Function environment.'
    );
  }

  const payload = {
    recipient,
    sender_id: senderId,
    type: 'plain',
    message,
  };

  const response = await fetch(TEXTLK_ENDPOINT, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify(payload),
  });

  const data = await response.json().catch(() => ({}));

  if (!response.ok || data.status === 'error') {
    const messageText = data.message || `Text.lk request failed with status ${response.status}.`;
    throw new functions.https.HttpsError('internal', messageText);
  }

  return data;
}

exports.sendOtp = functions.https.onCall(async (data) => {
  const phone = normalizeSriLankaPhone(data?.phone);
  const providedOtp = String(data?.otp || '').trim();
  const code = providedOtp || generateOtp();

  const message = `Your EcoRecycle verification code is ${code}. It expires in 5 minutes.`;
  const createdAt = admin.firestore.FieldValue.serverTimestamp();
  const expiresAt = admin.firestore.Timestamp.fromDate(new Date(Date.now() + 5 * 60 * 1000));

  const otpRef = db.collection(OTP_COLLECTION).doc();
  await otpRef.set({
    phone,
    otp: code,
    used: false,
    createdAt,
    expiresAt,
  });

  const sms = await sendTextlkSms({ recipient: phone, message });

  return {
    success: true,
    phone,
    otpId: otpRef.id,
    status: sms.status || 'success',
  };
});

exports.verifyOtp = functions.https.onCall(async (data) => {
  const phone = normalizeSriLankaPhone(data?.phone);
  const otp = String(data?.otp || '').trim();

  if (!otp) {
    throw new functions.https.HttpsError('invalid-argument', 'OTP is required.');
  }

  const query = await db
    .collection(OTP_COLLECTION)
    .where('phone', '==', phone)
    .where('otp', '==', otp)
    .where('used', '==', false)
    .limit(1)
    .get();

  if (query.empty) {
    throw new functions.https.HttpsError('not-found', 'Invalid or expired OTP.');
  }

  const doc = query.docs[0];
  const otpRecord = doc.data();
  const expiresAt = otpRecord.expiresAt;

  if (expiresAt && expiresAt.toDate && expiresAt.toDate() < new Date()) {
    await doc.ref.set({ used: true, expired: true }, { merge: true });
    throw new functions.https.HttpsError('deadline-exceeded', 'OTP has expired.');
  }

  await doc.ref.set({ used: true, verifiedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });

  return { success: true };
});

exports.sendBottleCount = functions.https.onCall(async (data) => {
  const phone = normalizeSriLankaPhone(data?.phone);
  const bottleCount = Number(data?.bottleCount || 0);
  const totalPoints = Number(data?.totalPoints || 0);

  const message = `EcoRecycle update: you have recycled ${bottleCount} bottles and earned ${totalPoints} points.`;
  const sms = await sendTextlkSms({ recipient: phone, message });

  return {
    success: true,
    phone,
    status: sms.status || 'success',
  };
});