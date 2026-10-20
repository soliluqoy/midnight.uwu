# Pigeon JNI bindings use literal JVM method descriptors from Dart.
# Keep descriptor class names too (notably kotlin.coroutines.Continuation),
# otherwise optimized preferences access fails even though the registrar survives.
-keep,includedescriptorclasses class io.flutter.plugins.sharedpreferences.SharedPreferencesAsyncApiRegistrar { *; }

# package:jni's Kotlin bridge also resolves these types and members by name.
# Preserve only this suspend-call ABI, not the whole Kotlin runtime.
-keep,includedescriptorclasses interface kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
-keep class kotlin.coroutines.intrinsics.IntrinsicsKt** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
