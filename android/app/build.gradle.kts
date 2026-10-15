import com.android.build.api.dsl.ApplicationExtension
import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- Release signing ----
// Credentials live in android/key.properties (gitignored; see README "Signing").
// When that file is absent, release builds are refused rather than quietly
// signed with the debug key — see the packageRelease guard at the bottom.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}

configure<ApplicationExtension> {
    namespace = "com.paulchukwuemeka.burrow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.paulchukwuemeka.burrow"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
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
            // Deliberately no debug-key fallback: a debug-signed APK shares the
            // applicationId but not the signature, so it could never update a
            // properly signed install — only replace it after an uninstall that
            // wipes the library. The packageRelease guard below turns a missing
            // key.properties into a clear error instead.
            signingConfig =
                if (keystorePropertiesFile.exists()) signingConfigs.getByName("release") else null
        }
    }
}

// Fail loudly (and early) when a release artifact would be unsigned, rather
// than shipping something that cannot update an installed build. Debug builds
// are unaffected: this runs only for release packaging tasks.
tasks.matching { it.name.startsWith("packageRelease") }.configureEach {
    doFirst {
        if (!keystorePropertiesFile.exists()) {
            throw GradleException(
                "Release build refused: android/key.properties is missing. Create it with " +
                    "storeFile, storePassword, keyAlias and keyPassword (see README \"Signing\"). " +
                    "Burrow does not fall back to the debug key: a debug-signed APK cannot " +
                    "update a release-signed install.",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

// ---- Burrow Rust engine (flutter_rust_bridge) ----
// Builds librust_lib_burrow.so for all Android ABIs via cargo-ndk and drops
// the .so files into src/main/jniLibs, which the Android source set picks up
// automatically. Declared inputs/outputs give Gradle up-to-date checks, so
// Dart-only edits skip the Rust build entirely.
val rustCrateDir = layout.projectDirectory.dir("../../rust")
val rustJniLibsDir = layout.projectDirectory.dir("src/main/jniLibs")

val buildRustEngine = tasks.register<Exec>("buildRustEngine") {
    group = "rust"
    description = "Builds the Burrow Rust engine (.so) for Android ABIs via cargo-ndk."

    // Only the crate sources feed the build. `rust/target` is deliberately NOT
    // an input, so a host-side `cargo build` (used by `flutter test`) or a
    // previous Gradle run cannot invalidate the task, and Dart-only edits never
    // trigger a Rust rebuild.
    inputs.files(rustCrateDir.file("Cargo.toml"), rustCrateDir.file("Cargo.lock"))
    inputs.dir(rustCrateDir.dir("src"))
    outputs.dir(rustJniLibsDir)

    // cargo-ndk needs the NDK. Prefer local.properties, then the environment.
    val sdkDir = Properties().let { props ->
        rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use(props::load)
        props.getProperty("sdk.dir")
    }
        ?: System.getenv("ANDROID_SDK_ROOT")
        ?: System.getenv("ANDROID_HOME")
        ?: ""
    val ndkHome = System.getenv("ANDROID_NDK_HOME")?.takeIf { it.isNotBlank() }
        ?: "$sdkDir/ndk/${flutter.ndkVersion}"

    // Make the Rust toolchain reachable even when Gradle runs under an IDE or a
    // daemon whose PATH omits ~/.cargo/bin.
    val pathEntries = (System.getenv("PATH") ?: "").split(":").toMutableList()
    val cargoBin = "${System.getProperty("user.home")}/.cargo/bin"
    if (cargoBin !in pathEntries) pathEntries.add(0, cargoBin)

    workingDir = rustCrateDir.asFile
    environment("ANDROID_NDK_HOME", ndkHome)
    environment("PATH", pathEntries.joinToString(":"))

    commandLine(
        "cargo", "ndk",
        "-t", "armeabi-v7a",
        "-t", "arm64-v8a",
        "-t", "x86_64",
        "-o", rustJniLibsDir.asFile.absolutePath,
        "build", "--release",
    )
}

// AGP merges each variant's JNI folders; make sure the Rust libs exist first.
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }
    .configureEach { dependsOn(buildRustEngine) }
