plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.pluginslab.smartterminal.pad"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.pluginslab.smartterminal.pad"
        minSdk = 33
        targetSdk = 36
        versionCode = 2
        versionName = "0.2.0"
    }
    // Release signing: the key's path and password come from ~/.gradle/gradle.properties
    // (never this repo); the key is backed up in ~/servers/CREDENTIALS.md.
    val storePath = providers.gradleProperty("smartterminal.storeFile").orNull
    signingConfigs {
        if (storePath != null) create("release") {
            storeFile = file(storePath)
            storePassword = providers.gradleProperty("smartterminal.password").get()
            keyAlias = "smartterminal"
            keyPassword = storePassword
        }
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"
            resValue("string", "app_name", "Smart Terminal Dev")
        }
        release {
            resValue("string", "app_name", "Smart Terminal")
            // No shrinking: sshj and Bouncy Castle find classes by reflection.
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
    packaging { resources.excludes += setOf("META-INF/*", "META-INF/versions/9/OSGI-INF/MANIFEST.MF") }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.icons)
    implementation(libs.activity.compose)
    implementation(libs.androidx.core)
    implementation(project(":terminal"))
    implementation(libs.sshj)
    implementation(libs.bcprov)
    implementation(libs.bcpkix)
    implementation(libs.yubikit.android)
    implementation(libs.yubikit.fido)
    implementation(libs.androidx.biometric)
    implementation(libs.androidx.fragment)
    testImplementation(libs.junit)
    testImplementation(libs.orgjson)  // Android's org.json is a stub in unit tests
}
