plugins {
    kotlin("multiplatform")
    kotlin("plugin.compose")
    id("org.jetbrains.compose")
    id("com.android.library")
}
kotlin {
    jvmToolchain(17)
    androidTarget()
    jvm()
    sourceSets {
        commonMain.dependencies {
            api(project(":shared"))
            api(compose.runtime)
            api(compose.foundation)
            implementation(compose.material3)
            implementation(compose.materialIconsExtended)
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.1")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
            implementation("com.mikepenz:multiplatform-markdown-renderer-m3:0.32.0")
            implementation("com.mikepenz:multiplatform-markdown-renderer-code:0.32.0")
            implementation("io.coil-kt.coil3:coil-compose:3.1.0")
            implementation("io.coil-kt.coil3:coil-network-core:3.1.0")
            implementation("io.ktor:ktor-client-core:3.0.3")
        }
        jvmTest.dependencies {
            implementation(compose.desktop.currentOs)
            implementation(compose.desktop.uiTestJUnit4)
            implementation(kotlin("test"))
            implementation("com.squareup.okhttp3:mockwebserver:4.12.0")
            implementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
        }
    }
}
android {
    namespace = "dev.nrc.chat.ui"; compileSdk = 35; defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
