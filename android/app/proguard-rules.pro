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

# Missing optional classes — suppress warnings
-dontwarn com.google.android.play.core.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
