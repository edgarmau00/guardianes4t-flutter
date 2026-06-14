# ML Kit Text Recognition
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }

-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

-keep class com.google.mlkit.vision.text.** { *; }

# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }