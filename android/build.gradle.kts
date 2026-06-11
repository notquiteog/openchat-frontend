allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val openchatAndroidCompileSdk =
    providers.gradleProperty("openchat.android.compileSdk")
        .map(String::toInt)
        .getOrElse(36)

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
        // JDK 26 warns for plugins that still compile Java 8 sources.
        if (!options.compilerArgs.contains("-Xlint:-options")) {
            options.compilerArgs.add("-Xlint:-options")
        }
    }

    plugins.withId("org.jetbrains.kotlin.android") {
        extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }

    afterEvaluate {
        extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.apply {
            // Some Flutter plugins pin lower compileSdk values in their own
            // Gradle files. Lift every Android module to the app API level.
            compileSdkVersion(openchatAndroidCompileSdk)
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
