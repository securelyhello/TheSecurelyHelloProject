import java.util.Properties

// Release signing: create android/key.properties (git-ignored) with
//   storeFile=/absolute/path/to/upload-keystore.jks
//   storePassword=...  keyAlias=...  keyPassword=...
// If the file exists, all four keys are required (the build fails otherwise,
// rather than silently shipping a debug-signed release). Without the file,
// assembleRelease / bundleRelease fail too, unless you opt in to a
// debug-signed release for local testing (not accepted by Play Store):
//   flutter build apk --release --android-project-arg=allowDebugSignedRelease=true
//   ./gradlew assembleRelease -PallowDebugSignedRelease=true
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}
val hasReleaseKey = keystorePropertiesFile.exists()
if (hasReleaseKey) {
    val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (missing.isNotEmpty()) {
        throw GradleException(
            "android/key.properties is missing ${missing.joinToString(", ")}; " +
                "set all of storeFile, storePassword, keyAlias and keyPassword (or remove the file)",
        )
    }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "securelyhello.thenn"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "securelyhello.thenn.in"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

// See the signing note at the top: a release build without a release key
// fails unless -PallowDebugSignedRelease=true is passed.
val allowDebugSignedRelease =
    (findProperty("allowDebugSignedRelease") as String?)?.toBoolean() == true
if (!hasReleaseKey) {
    gradle.taskGraph.whenReady {
        val releaseTasks = allTasks.filter {
            it.project == project && it.name.contains("Release")
        }
        val packagesRelease = releaseTasks.any {
            it.name == "assembleRelease" || it.name == "bundleRelease"
        }
        if (packagesRelease && !allowDebugSignedRelease) {
            throw GradleException(
                "android/key.properties not found: refusing to build a release signed with the " +
                    "DEBUG key. Add key.properties (see the top of android/app/build.gradle.kts), " +
                    "or pass -PallowDebugSignedRelease=true for a local test build.",
            )
        }
        if (releaseTasks.isNotEmpty()) {
            logger.warn(
                "WARNING: android/key.properties not found: this release build is signed with " +
                    "the DEBUG key and cannot be uploaded to Play Store.",
            )
        }
    }
}
