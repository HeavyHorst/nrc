pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "nrc-mobile"
include(":shared", ":ui", ":androidApp", ":preview")
