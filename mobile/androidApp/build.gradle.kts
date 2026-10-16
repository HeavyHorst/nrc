import groovy.json.JsonSlurper

plugins { kotlin("android"); kotlin("plugin.compose"); id("com.android.application") }
val signingDirectory = providers.environmentVariable("NRC_ANDROID_SIGNING_DIRECTORY").orNull
val tailscaleControlURL = providers.gradleProperty("nrcTailscaleControlURL").orNull.orEmpty()
android {
    namespace = "dev.nrc.chat"
    compileSdk = 35
    defaultConfig {
        applicationId = "dev.nrc.chat"
        minSdk = 26; targetSdk = 35; versionCode = 19; versionName = "0.2.17"
        buildConfigField("String", "TAILSCALE_CONTROL_URL", groovy.json.JsonOutput.toJson(tailscaleControlURL))
        ndk { abiFilters += "arm64-v8a" }
    }
    if (signingDirectory != null) {
        val credentials = JsonSlurper().parse(file("$signingDirectory/signing.json")) as Map<*, *>
        signingConfigs.getByName("debug") {
            storeFile = file("$signingDirectory/keystore.p12")
            storeType = "PKCS12"
            storePassword = credentials["store_password"] as String
            keyAlias = credentials["key_alias"] as String
            keyPassword = credentials["key_password"] as String
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
val tailnetAar = tasks.register<Exec>("buildEmbeddedTailnet") {
    workingDir = rootProject.file("tsnet")
    commandLine("bash", "build-android.sh")
    inputs.files(rootProject.fileTree("tsnet") { include("*.go", "go.mod", "go.sum", "build-android.sh") })
    outputs.file(rootProject.file("tsnet/build/tailnet.aar"))
}
tasks.named("preBuild").configure { dependsOn(tailnetAar) }
// Never silently replace the identity already installed on testers' phones.
tasks.configureEach {
    if (name == "validateSigningDebug") {
        outputs.upToDateWhen { false }
        doFirst {
            check(signingDirectory != null) { "Build the APK with mobile/sign-debug-apk.sh, not the default Android debug key." }
        }
    }
}
dependencies {
    implementation(files(rootProject.file("tsnet/build/tailnet.aar")))
    implementation(project(":ui"))
    implementation(project(":shared"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("io.ktor:ktor-client-okhttp:3.0.3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("app.cash.sqldelight:android-driver:2.0.2")
    testImplementation("junit:junit:4.13.2")
}
