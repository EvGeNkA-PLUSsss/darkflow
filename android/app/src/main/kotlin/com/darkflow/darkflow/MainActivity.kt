package com.darkflow.darkflow

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * The Android side of the runtime channel.
 *
 * DarkFlow runs Tor and its pluggable transports as child processes. Android
 * only allows an app to execute code from its read-only native library
 * directory, and the path to that directory is not derivable from Dart — it
 * contains a per-install hash. The platform hands it out as
 * `ApplicationInfo.nativeLibraryDir`, so it is passed across here rather than
 * guessed from the executable path.
 *
 * It is passed **twice**, on purpose. The channel is the clean route, but it
 * needs the Flutter engine to be up and the plugin registered, and a lookup
 * that happens a moment too early fails with `MissingPluginException` — which
 * is exactly what left the app reporting that the Tor library "is not packaged
 * in this build" while the library sat in the APK. The file is written from
 * `onCreate`, before the engine exists, and cannot miss that window.
 */
class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        writeNativeLibraryDir()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Records [android.content.pm.ApplicationInfo.nativeLibraryDir] where Dart
     * can find it without a channel.
     *
     * A failure here is not worth crashing over: the channel remains, and if
     * both are unavailable the Dart side reports precisely what it tried.
     */
    private fun writeNativeLibraryDir() {
        try {
            File(filesDir, MARKER_FILE).writeText(applicationInfo.nativeLibraryDir)
        } catch (error: IOException) {
            // Nothing to do; the channel is still there.
        }
    }

    private companion object {
        const val CHANNEL = "darkflow/runtime"
        const val MARKER_FILE = "native_library_dir"
    }
}
