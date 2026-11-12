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
        versionCode = 1
        versionName = "0.0.1"
    }
    buildTypes {
        debug { applicationIdSuffix = ".dev" }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }
    packaging { resources.excludes += setOf("META-INF/*", "META-INF/versions/9/OSGI-INF/MANIFEST.MF") }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.activity.compose)
    implementation(libs.androidx.core)
    implementation(project(":terminal"))
    implementation(libs.sshj)
    implementation(libs.bcprov)
    implementation(libs.bcpkix)
}
