plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.yokayo.music"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.yokayo.music"
        minSdk = 26
        targetSdk = 35
        versionCode = 10
        versionName = "0.8"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            // подпись отладочным ключом — чтобы APK ставился напрямую
            signingConfig = signingConfigs.getByName("debug")
            buildConfigField("boolean", "PREVIEW", "false")
        }
        debug {
            // сборка для скриншотов: интерфейс без входа, без отладчика — чтобы не тормозила
            isDebuggable = false
            buildConfigField("boolean", "PREVIEW", "true")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.media3:media3-session:1.5.1")
    implementation("androidx.media3:media3-common:1.5.1")
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("androidx.palette:palette-ktx:1.0.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.guava:guava:33.3.1-android")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.9.0")
    testImplementation("junit:junit:4.13.2")
}
