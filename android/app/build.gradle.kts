import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import org.jetbrains.kotlin.konan.properties.Properties
import java.util.Base64
import java.security.MessageDigest
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val agpMajorVersion = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION
    .substringBefore('.')
    .toInt()
val builtInKotlinProperty = providers.gradleProperty("android.builtInKotlin").orNull
val isBuiltInKotlinEnabled = agpMajorVersion >= 9 &&
        (builtInKotlinProperty == null || builtInKotlinProperty.toBoolean())
if (!isBuiltInKotlinEnabled) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "com.personal.piliplus"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.personal.piliplus"
        minSdk = flutter.minSdkVersion
        targetSdk = 37
        versionCode = flutter.versionCode
        versionName = "${flutter.versionName}-功耗修复"
    }

    packagingOptions.jniLibs.useLegacyPackaging = true

    val keyProperties = Properties().also {
        val properties = rootProject.file("key.properties")
        if (properties.exists())
            it.load(properties.inputStream())
    }

    val config = keyProperties.getProperty("storeFile")?.let {
        signingConfigs.create("release") {
            storeFile = file(it)
            storePassword = keyProperties.getProperty("storePassword")
            keyAlias = keyProperties.getProperty("keyAlias")
            keyPassword = keyProperties.getProperty("keyPassword")
            enableV1Signing = true
            enableV2Signing = true
        }
    }

    buildFeatures {
        if (project.hasProperty("dev")) {
            resValues = true
        }
    }

    buildTypes {
        all {
            signingConfig = config ?: signingConfigs["debug"]
        }
        release {
            val playbackTrace = project.findProperty("dart-defines")?.toString()?.split(",")?.any {
                runCatching {
                    String(Base64.getDecoder().decode(it), Charsets.UTF_8) == "PLAYBACK_TRACE=true"
                }.getOrDefault(false)
            } == true
            if (playbackTrace) {
                proguardFiles("playback-diagnostics-rules.pro")
            }
            if (project.hasProperty("dev")) {
                applicationIdSuffix = ".dev"
                resValue(
                    type = "string",
                    name = "app_name",
                    value = "PiliPlus dev",
                )
            }
//            proguardFiles(
//                getDefaultProguardFile("proguard-android-optimize.txt"),
//                "proguard-rules.pro"
//            )
        }
        debug {
            applicationIdSuffix = ".debug"
        }
    }

    applicationVariants.all {
        val variant = this
        variant.outputs.forEach { output ->
            (output as ApkVariantOutputImpl).versionCodeOverride = flutter.versionCode
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
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1") {
        // These tests exercise View measurement/layout, not native raster.
        exclude(group = "org.robolectric", module = "nativeruntime-dist-compat")
    }
}

tasks.withType<Test>().configureEach {
    systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
}

// Release builds must retain the verified playback profile. Experiments opt out
// explicitly; an ordinary build may never silently ship the default player.
if (!project.hasProperty("piliStartupExperiment")) {
    val profile = JsonSlurper().parse(rootProject.file("../tool/release_profile.json")) as Map<*, *>
    val expected = profile["defines"] as Map<*, *>
    val configured = providers.gradleProperty("dart-defines").orNull.orEmpty()
        .split(",").mapNotNull { encoded ->
            runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull()
        }.mapNotNull { value ->
            val split = value.indexOf('=')
            if (split < 0) null else value.substring(0, split) to value.substring(split + 1)
        }.toMap()
    tasks.matching { it.name == "compileFlutterBuildRelease" }.configureEach {
        doFirst {
            val missing = expected.filter { (key, value) ->
                // Instrumentation may be enabled in an explicit benchmark build.
                key !in listOf("PLAYBACK_TRACE", "STARTUP_TIMING") && configured[key] != value
            }
            check(missing.isEmpty()) {
                "Missing preserved r116 playback flags: ${missing.keys}. Build with tool/build_verified_release.py"
            }
        }
    }
    tasks.matching { it.name == "mergeReleaseNativeLibs" }.configureEach {
        doLast {
            val natives = profile["native"] as Map<*, *>
            val platforms = providers.gradleProperty("target-platform").orNull.orEmpty().split(',')
            for (platform in platforms) {
                val spec = natives[platform] as? Map<*, *> ?: error("No verified player for $platform")
                val abi = (spec["entry"] as String).split('/')[1]
                val libraries = outputs.files.asFileTree.matching { include("**/$abi/libmpv.so") }.files
                check(libraries.isNotEmpty()) { "Missing native player for $abi" }
                libraries.forEach { library ->
                    val hash = MessageDigest.getInstance("SHA-256").digest(library.readBytes())
                        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                    check(hash == spec["sha256"]) { "Unverified libmpv for $abi: $hash" }
                }
            }
        }
    }
}
