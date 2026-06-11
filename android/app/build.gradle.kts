import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val googleServicesFiles = listOf(
    file("google-services.json"),
    file("src/debug/google-services.json"),
    file("src/release/google-services.json"),
    file("src/main/google-services.json"),
)
if (googleServicesFiles.any { it.exists() }) {
    apply(plugin = "com.google.gms.google-services")
}

// CI writes android/key.properties before invoking Gradle.
// Local devs can do the same; if the file is absent the debug key is used.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.exists()) load(keyPropertiesFile.inputStream())
}

val openchatCompileSdk =
    providers.gradleProperty("openchat.android.compileSdk")
        .map(String::toInt)
        .getOrElse(flutter.compileSdkVersion)
val openchatTargetSdk =
    providers.gradleProperty("openchat.android.targetSdk")
        .map(String::toInt)
        .getOrElse(flutter.targetSdkVersion)

android {
    namespace = "com.openchat.openchat"
    compileSdk = openchatCompileSdk
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.openchat.openchat"
        minSdk = flutter.minSdkVersion
        targetSdk = openchatTargetSdk
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyPropertiesFile.exists()) {
            create("release") {
                storeFile = file(keyProperties["storeFile"] as String)
                storePassword = keyProperties["storePassword"] as String
                keyAlias = keyProperties["keyAlias"] as String
                keyPassword = keyProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keyPropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
