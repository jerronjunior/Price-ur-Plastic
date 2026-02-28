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
    apiKey: 'AIzaSyBayhvqyLUVgZ_1dvAE1JwWeRNC77zST_A',
    appId: '1:71140175089:web:8b1293315d4d02d7818d50',
    messagingSenderId: '71140175089',
    projectId: 'price-ur-plastic-faab5',
    authDomain: 'price-ur-plastic-faab5.firebaseapp.com',
    storageBucket: 'price-ur-plastic-faab5.firebasestorage.app',
    measurementId: 'G-EDYCJB0YZZ',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDfFAzePht8j1YIsnGABUZikm7tTwyvLIU',
    appId: '1:71140175089:android:6bb69b793b333018818d50',
    messagingSenderId: '71140175089',
    projectId: 'price-ur-plastic-faab5',
    storageBucket: 'price-ur-plastic-faab5.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyDMhNS3Xm3fFU2we5WY3LlbIgoe4fT9mrU',
    appId: '1:71140175089:ios:9d43ef8b7be0726d818d50',
    messagingSenderId: '71140175089',
    projectId: 'price-ur-plastic-faab5',
    storageBucket: 'price-ur-plastic-faab5.firebasestorage.app',
    iosBundleId: 'com.example.ecoRecycle',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyDMhNS3Xm3fFU2we5WY3LlbIgoe4fT9mrU',
    appId: '1:71140175089:ios:9d43ef8b7be0726d818d50',
    messagingSenderId: '71140175089',
    projectId: 'price-ur-plastic-faab5',
    storageBucket: 'price-ur-plastic-faab5.firebasestorage.app',
    iosBundleId: 'com.example.ecoRecycle',
  );

}