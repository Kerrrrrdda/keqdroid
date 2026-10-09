import java.util.Properties

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.google.gms:google-services:4.4.2")
        classpath("com.google.firebase:firebase-crashlytics-gradle:3.0.7")
    }
}

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// google-services.json is gitignored — apply plugins only when the file exists locally
val googleServicesJson = file("google-services.json")
if (googleServicesJson.exists()) {
    apply(plugin = "com.google.gms.google-services")
    apply(plugin = "com.google.firebase.crashlytics")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

// A local checkout may not have a release keystore (key.properties and *.jks
// are deliberately gitignored). In that case, local --release builds use the
// Android debug key instead of trying to open a file literally named "null".
// The release packaging script separately requires a real release key.
val releaseStoreFile = keystoreProperties.getProperty("storeFile")
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
    ?.let { file(it) }
val releaseSigningConfigured =
    keystorePropertiesFile.isFile &&
        listOf("keyAlias", "keyPassword", "storePassword")
            .all { !keystoreProperties.getProperty(it).isNullOrBlank() } &&
        releaseStoreFile?.isFile == true

if (!releaseSigningConfigured) {
    logger.warn(
        "No valid Android release keystore found; local release/profile builds will use the " +
            "debug signing key. Such APKs cannot update installations signed with another key."
    )
}

// Архитектура APK. В релизе их две: основной arm64-v8a и armeabi-v7a для
// телефонов, где производитель поставил 32-битный Android на 64-битный чип
// (Redmi 9A/9C), — arm64-APK там не ставится вовсе. Какую собирать, Flutter
// передаёт свойством target-platform из `flutter build apk --target-platform`.
// Всё, что не ровно android-arm (flutter run, сборка без флага), — arm64, как
// было до 32-битной сборки.
val targetAbi =
    if (project.findProperty("target-platform") == "android-arm") "armeabi-v7a" else "arm64-v8a"

android {
    namespace = "com.keqdroid.keqdroid"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.keqdroid.keqdroid"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Одна архитектура на APK (см. targetAbi). x86_64 не собирается:
            // ядер под него нет, и VPN на нём был нерабочим.
            abiFilters += listOf(targetAbi)
        }
    }

    // Строки ресурсов только на языках самого приложения (lib/l10n). Библиотеки
    // приносили их примерно на 85 языках, а интерфейс на любом другом языке
    // системы всё равно английский — их кнопки и так были бы не в тон ему.
    // Список держать в ногу с lib/l10n: язык, которого здесь нет, потеряет
    // перевод плитки и ярлыков из res/values-*.
    androidResources {
        localeFilters += listOf("en", "ru", "de", "zh", "fa")
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // `abiFilters` выше до чужих библиотек не достаёт: ML Kit из
            // mobile_scanner приносит libbarhopper_v3.so в AAR, и в APK
            // приезжали ВСЕ три её сборки — x86_64 на 5.9 МБ и armeabi-v7a на
            // 3.2 МБ поверх нужной. С двумя наборами ядер в jniLibs то же
            // самое стоило бы ещё ~80 МБ соседней архитектуры. Поэтому APK
            // берёт только свою, а make_release.ps1 проверяет это по готовому
            // файлу.
            excludes += listOf("x86", "x86_64", "armeabi-v7a", "arm64-v8a")
                .filter { it != targetAbi }
                .map { "**/$it/**" }
        }
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias").trim()
                keyPassword = keystoreProperties.getProperty("keyPassword").trim()
                storeFile = requireNotNull(releaseStoreFile)
                storePassword = keystoreProperties.getProperty("storePassword").trim()
            }
        }
    }

    buildTypes {
        // Keep profile and release on the same key when a release keystore is
        // configured. On a fresh checkout, use the debug key for local testing.
        // tool/make_release.ps1 refuses to package an APK without a real key.
        val localSigningConfig = if (releaseSigningConfigured) {
            signingConfigs.getByName("release")
        } else {
            signingConfigs.getByName("debug")
        }
        maybeCreate("profile").signingConfig = localSigningConfig

        release {
            signingConfig = localSigningConfig
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
    // sing-box owns Android's TUN and routes each package to a dedicated SOCKS outbound.
    implementation("com.github.singbox-android:libbox:1.14.2")
}
