plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.offline.offline"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.offline.offline"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // SECURITY (S-10): debug-signed releases are not upgrade-safe and use a
            // publicly-known key. Configure a real release keystore (e.g. via
            // key.properties + signingConfigs.release) before distributing v* tags.
            // Kept as debug only so local `flutter run --release` still works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    // Relative to android/app/ → Flutter project root (contains pubspec.yaml).
    source = "../.."
}
