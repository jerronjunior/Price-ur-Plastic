# EcoRecycle

Flutter mobile app to reduce plastic bottle waste. Users scan bottle barcodes, confirm insertion via camera, and earn points.

## Phase 1 Features
- Firebase Auth (email/password), register, login, logout
- Home: total points, total bottles, Scan Bottle button
- Scan flow: Scan bin QR → Scan bottle barcode → Camera 10s countdown + arrow-region detection → +1 point
- Leaderboard (top 10, real-time), Profile (edit name, stats), Rewards (Bronze 50, Silver 200, Gold 500)
- Firestore: users, recycled_bottles, bins; security rules and indexes included

## Setup
1. `flutter pub get`
2. **Firebase**: Run `dart run flutterfire_cli:flutterfire configure` (adds Android/iOS and generates `lib/firebase_options.dart`). Replace the placeholder `lib/firebase_options.dart` with the generated file.
3. **Firestore**: In Firebase Console, deploy rules from `firestore.rules` and indexes from `firestore.indexes.json`.
4. **Storage**: Deploy rules from `storage.rules` so signed-in users can upload profile pictures to `profile_images/{uid}/...`.
5. **Bins**: Create at least one document in the `bins` collection (e.g. `binId`: "BIN001", `locationName`: "Main Lobby") so that scanning a QR with that ID works.
6. Run `flutter run`

## Text.lk SMS setup
1. Put your Firebase Functions code in the `functions/` folder.
2. Set the SMS config before deploy:
	`firebase functions:config:set textlk.api_token="YOUR_TEXTLK_TOKEN" textlk.sender_id="RecycleScan"`
3. Deploy functions:
	`firebase deploy --only functions`
4. The app already calls the SMS function after a bottle is saved. For OTP flows, call `SmsService().sendOtp(phone: '9477...')` from the screen where the user enters their phone number, then verify with `SmsService().verifyOtp(...)`.
