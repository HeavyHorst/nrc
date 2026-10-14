plugins { kotlin("multiplatform"); kotlin("plugin.compose"); id("org.jetbrains.compose") }
kotlin {
    jvm()
    sourceSets.jvmMain.dependencies {
        implementation(project(":ui"))
        implementation(project(":shared"))
        implementation(compose.desktop.currentOs)
        implementation(compose.material3)
        implementation("io.ktor:ktor-client-cio:3.0.3")
        implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
        implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
        implementation("app.cash.sqldelight:sqlite-driver:2.0.2")
    }
}
compose.desktop { application { mainClass = "dev.nrc.chat.preview.MainKt" } }
