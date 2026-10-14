plugins {
    kotlin("multiplatform")
    kotlin("plugin.serialization")
    id("com.android.library")
    id("app.cash.sqldelight")
}
kotlin {
    jvmToolchain(17)
    androidTarget()
    jvm()
    // Apple frameworks are built with Xcode on a Mac, not on Linux.
    if (System.getProperty("os.name") == "Mac OS X") {
        listOf(iosArm64(), iosSimulatorArm64()).forEach {
            it.binaries.framework { baseName = "NrcChat" }
        }
    }
    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
            implementation("org.jetbrains.kotlinx:kotlinx-datetime:0.6.1")
            implementation("io.ktor:ktor-client-core:3.0.3")
            implementation("io.ktor:ktor-client-websockets:3.0.3")
            implementation("app.cash.sqldelight:runtime:2.0.2")
        }
        commonTest.dependencies { implementation(kotlin("test")) }
        jvmMain.dependencies { implementation("io.ktor:ktor-client-cio:3.0.3") }
        jvmTest.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
            implementation("app.cash.sqldelight:sqlite-driver:2.0.2")
            implementation("com.squareup.okhttp3:mockwebserver:4.12.0")
            implementation("com.squareup.okhttp3:okhttp-tls:4.12.0")
            implementation("io.ktor:ktor-client-okhttp:3.0.3")
        }
    }
}
sqldelight {
    databases { create("ChatDatabase") { packageName.set("dev.nrc.chat.db") } }
}
android {
    namespace = "dev.nrc.chat.core"; compileSdk = 35; defaultConfig { minSdk = 26 }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
