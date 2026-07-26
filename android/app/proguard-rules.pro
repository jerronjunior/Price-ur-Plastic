# Keep reflection metadata needed by Firebase and Kotlin
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses
-keepattributes NestHost
-keepattributes NestMembers

# Firebase Core
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Firebase Storage generated classes
-keep class io.flutter.plugins.firebase.storage.** { *; }
-keep class io.flutter.plugins.firebase.storage.GeneratedAndroidFirebaseStorage** { *; }

# Pigeon generated files
-keep class com.google.firebase.storage.pigeon.** { *; }
-keep interface com.google.firebase.storage.pigeon.** { *; }

# TFLite — native/JNI bridge classes get stripped by R8 on some OEM builds
# since nothing in the bytecode visibly references them (they're called from
# native code), which shows up as a release-only crash that debug builds
# never hit.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**

# mobile_scanner (ML Kit barcode scanning) — same native-bridge risk as above.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }

# Missing optional classes — suppress warnings
-dontwarn com.google.android.play.core.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
