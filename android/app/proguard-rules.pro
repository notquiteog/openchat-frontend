# ffmpeg_kit_flutter_new_min ships keep rules but wires them with
# `proguardFiles` instead of `consumerProguardFiles`, so they never reach this
# app's R8 run. Without a hard keep, R8 removes AbiDetect.getNativeCpuAbi()
# (it is registered from native JNI_OnLoad via RegisterNatives and never
# called from Java, so the default `-keepclasseswithmembernames ... native`
# rule's allowshrinking lets it go). RegisterNatives then fails, JNI_OnLoad
# returns 0, and the resulting UnsatisfiedLinkError — an Error, not an
# Exception — escapes GeneratedPluginRegistrant's per-plugin catch(Exception)
# and aborts ALL plugin registration: every release build launched to a black
# screen with MissingPluginException on every channel.
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-dontwarn com.antonkarpenko.ffmpegkit.**

# Same failure shape is possible for any plugin whose .so registers natives
# against Java methods the Java side never calls. Pin the native-method names
# of every class that declares natives (no allowshrinking, unlike the AGP
# default rule) so RegisterNatives can always resolve them.
-keepclasseswithmembers class * {
    native <methods>;
}
