allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Plugins like file_picker guard their `apply plugin: 'kotlin-android'` behind
    // an AGP-version check, so Flutter's static-text scan thinks they self-manage
    // KGP and doesn't apply it — leaving their Kotlin sources without a compiler.
    // Applying KGP here fires synchronously when com.android.library is applied,
    // before each plugin's own conditional runs. Applying it twice is a no-op.
    plugins.withId("com.android.library") {
        apply(plugin = "org.jetbrains.kotlin.android")
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
