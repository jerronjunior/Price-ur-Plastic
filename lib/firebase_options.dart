import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_WEB_API_KEY', defaultValue: 'REPLACE_ME'),
    appId: String.fromEnvironment('FIREBASE_WEB_APP_ID', defaultValue: 'REPLACE_ME'),
    messagingSenderId: String.fromEnvironment('FIREBASE_WEB_MESSAGING_SENDER_ID', defaultValue: 'REPLACE_ME'),
    projectId: String.fromEnvironment('FIREBASE_WEB_PROJECT_ID', defaultValue: 'REPLACE_ME'),
    authDomain: String.fromEnvironment('FIREBASE_WEB_AUTH_DOMAIN', defaultValue: 'REPLACE_ME'),
    storageBucket: String.fromEnvironment('FIREBASE_WEB_STORAGE_BUCKET', defaultValue: 'REPLACE_ME'),
    measurementId: String.fromEnvironment('FIREBASE_WEB_MEASUREMENT_ID', defaultValue: 'REPLACE_ME'),
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_ANDROID_API_KEY', defaultValue: 'REPLACE_ME'),
    appId: String.fromEnvironment('FIREBASE_ANDROID_APP_ID', defaultValue: 'REPLACE_ME'),
    messagingSenderId: String.fromEnvironment('FIREBASE_ANDROID_MESSAGING_SENDER_ID', defaultValue: 'REPLACE_ME'),
    projectId: String.fromEnvironment('FIREBASE_ANDROID_PROJECT_ID', defaultValue: 'REPLACE_ME'),
    storageBucket: String.fromEnvironment('FIREBASE_ANDROID_STORAGE_BUCKET', defaultValue: 'REPLACE_ME'),
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_IOS_API_KEY', defaultValue: 'REPLACE_ME'),
    appId: String.fromEnvironment('FIREBASE_IOS_APP_ID', defaultValue: 'REPLACE_ME'),
    messagingSenderId: String.fromEnvironment('FIREBASE_IOS_MESSAGING_SENDER_ID', defaultValue: 'REPLACE_ME'),
    projectId: String.fromEnvironment('FIREBASE_IOS_PROJECT_ID', defaultValue: 'REPLACE_ME'),
    storageBucket: String.fromEnvironment('FIREBASE_IOS_STORAGE_BUCKET', defaultValue: 'REPLACE_ME'),
    iosBundleId: String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID', defaultValue: 'REPLACE_ME'),
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: String.fromEnvironment('FIREBASE_MACOS_API_KEY', defaultValue: 'REPLACE_ME'),
    appId: String.fromEnvironment('FIREBASE_MACOS_APP_ID', defaultValue: 'REPLACE_ME'),
    messagingSenderId: String.fromEnvironment('FIREBASE_MACOS_MESSAGING_SENDER_ID', defaultValue: 'REPLACE_ME'),
    projectId: String.fromEnvironment('FIREBASE_MACOS_PROJECT_ID', defaultValue: 'REPLACE_ME'),
    storageBucket: String.fromEnvironment('FIREBASE_MACOS_STORAGE_BUCKET', defaultValue: 'REPLACE_ME'),
    iosBundleId: String.fromEnvironment('FIREBASE_MACOS_BUNDLE_ID', defaultValue: 'REPLACE_ME'),
  );
}
