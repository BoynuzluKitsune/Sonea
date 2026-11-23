# Flutter, AudioService, Media3, Sonea Widgets, Plugins & Rust Bridge keep rules
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }
-keep class androidx.media3.** { *; }
-keep class androidx.media.** { *; }
-keep class com.sonea.app.** { *; }
-keep class com.sonea.app.widget.** { *; }
-keep class * extends android.appwidget.AppWidgetProvider { *; }
-keep class * extends com.sonea.app.widget.SoneaWidgetBase { *; }

# Keep RemoteViews / AnimatedVectorDrawable / ViewFlipper reflection targets
-keep class android.graphics.drawable.AnimatedVectorDrawable { *; }
-keepclassmembers class android.widget.ProgressBar {
    public void setIndeterminateTintList(android.content.res.ColorStateList);
}
-keepclassmembers class android.widget.ImageView {
    public void setColorFilter(int);
}

# Flutter engine & plugins (path_provider, shared_preferences, jni, frb)
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class dev.flutter.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod
-keep class kotlin.Metadata { *; }

-dontwarn com.ryanheise.audioservice.**
-dontwarn com.ryanheise.just_audio.**
-dontwarn androidx.media3.**
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**
-dontwarn com.sun.jna.**
-dontwarn com.github.dart_lang.jni.**
