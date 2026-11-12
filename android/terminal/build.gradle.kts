plugins { alias(libs.plugins.android.library) }

android {
    namespace = "com.termux.view"
    compileSdk = 36
    defaultConfig { minSdk = 33 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies { implementation(libs.androidx.annotation) }
