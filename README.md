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
4. **Bins**: Create at least one document in the `bins` collection (e.g. `binId`: "BIN001", `locationName`: "Main Lobby") so that scanning a QR with that ID works.
5. Run `flutter run`
