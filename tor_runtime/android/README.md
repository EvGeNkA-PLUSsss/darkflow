# Android Tor runtime

Nothing lives here, and that is the point.

Android forbids executing code from an app's private storage, so Tor cannot be
shipped as an asset and unpacked the way it is on Windows. It ships as native
libraries instead:

```
android/app/src/main/jniLibs/arm64-v8a/libtor.so
android/app/src/main/jniLibs/arm64-v8a/liblyrebird.so
android/app/src/main/jniLibs/arm64-v8a/libobfs4proxy.so
android/app/src/main/jniLibs/arm64-v8a/libsnowflake-client.so
android/app/src/main/jniLibs/arm64-v8a/libwebtunnel-client.so
android/app/src/main/jniLibs/arm64-v8a/libmeek-client.so
android/app/src/main/jniLibs/arm64-v8a/libconjure-client.so
```

`TorBinaryLocator` finds them through
`ApplicationInfo.nativeLibraryDir`, which `MainActivity` reports over a method
channel and also writes to a marker file, and runs them from there. Nothing under
`assets/` is consulted on Android.

See `tool/make_pt_sources.ps1`, `tool/build_android_pt.ps1` and
`tool/verify_android_pt.ps1` for how those binaries are produced and verified.
