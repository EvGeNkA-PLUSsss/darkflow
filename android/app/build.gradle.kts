import java.io.File as JavaFile
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material, read from `android/keystore.properties`.
//
// That file is deliberately not in version control (see the repository
// .gitignore) because it names a keystore and its passwords. It looks like:
//
//     storeFile=darkflow-release.jks
//     storePassword=...
//     keyAlias=darkflow
//     keyPassword=...
//
// `storeFile` is resolved against `android/` unless it is an absolute path.
//
// When the file is absent the release build falls back to the debug signing
// config, which is what makes `flutter build apk --release` work on a machine
// with no keys - a contributor running a release build to check for
// tree-shaking-only errors, for instance. The consequence is stated rather than
// hidden: such an APK cannot be published, and it will not upgrade an
// installation that was signed with the real key. `tool/build_android.ps1`
// prints a warning in that case.
//
// `java.io.File` is imported as `JavaFile` because the unqualified `File` in a
// Gradle Kotlin DSL script resolves to the Android Gradle Plugin's own DSL helper
// (`File(String, Int)`), and the collision produces a "none of the following
// candidates is applicable" error rather than a wrong path.
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { stream ->
        keystoreProperties.load(stream)
    }
}

android {
    namespace = "com.darkflow.darkflow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by `flutter_local_notifications`, whose metadata declares it.
        //
        // Desugaring back-ports the `java.time` API to older Android releases, and
        // the plugin uses it to compute scheduled-notification times. Without this the
        // release build fails at `checkReleaseAarMetadata` — a build-time refusal
        // rather than a runtime crash, which is the good version of this problem: the
        // alternative would be an app that installs and then throws the moment a
        // notification is posted on an older phone.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.darkflow.darkflow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // arm64-v8a only, until the Tor binaries exist for the others.
        //
        // The alternative is an APK that installs happily on a 32-bit phone and
        // then fails at the moment the user presses Connect, because libtor.so
        // is not there. Shipping one ABI that fully works is better than three
        // where one does; adding armeabi-v7a and x86_64 is a matter of putting
        // their binaries in jniLibs and deleting this filter.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // `rootProject.file` is used rather than `project.file` because
                // the latter resolves relative paths against `android/app`, and
                // the keystore lives in `android/`.
                val declared = keystoreProperties.getProperty("storeFile")
                storeFile = if (declared != null && JavaFile(declared).isAbsolute) {
                    JavaFile(declared)
                } else {
                    rootProject.file(declared ?: "keystore.jks")
                }
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // No keystore on this machine. Debug keys keep the release build
                // runnable and are loudly not publishable; see the note above.
                signingConfigs.getByName("debug")
            }
            // The Dart build already tree-shakes and obfuscates nothing by
            // default, and shrinking is left off on purpose: the app runs Tor and
            // its transports as child processes found by name at runtime, and a
            // resource shrinker that renames or strips anything they touch turns
            // a working connection into a silent failure on a device we cannot
            // debug. The APK is large because Tor is large, not because of dead
            // code.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            // Tor and its pluggable transports are executed as child processes,
            // so they have to exist as real files on disk.
            //
            // Since AGP 4.2 native libraries are, by default, left compressed
            // inside the APK and mapped straight out of it. That is fine for
            // `dlopen` and fatal for `exec`: ApplicationInfo.nativeLibraryDir
            // would point at a directory with nothing in it. Legacy packaging
            // extracts them, which is the whole point of shipping a daemon this
            // way.
            useLegacyPackaging = true
        }

        // Note: the Windows Tor runtime is kept out of the APK by pubspec.yaml,
        // not from here.
        //
        // `packaging.resources` does not apply to Flutter's assets, which are
        // merged as Android *assets*, and this AGP version has no
        // `packaging.assets` block to do it properly. pubspec.yaml therefore
        // declares `assets/tor/android/` alongside `assets/tor/windows/`: the
        // Android directory holds one small text file and the Windows one holds
        // 119 MB of .exe files, so each build carries only its own.
        // `tool/build_android.ps1` verifies the result rather than arranging it.
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The desugaring runtime itself. `isCoreLibraryDesugaringEnabled` above turns the
    // rewriting on; this is the library the rewritten calls resolve to at run time,
    // and without it the build fails with "core library desugaring to be enabled"
    // even though it is.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
