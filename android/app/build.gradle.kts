import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 自己的签名（可选）。`android/key.properties` 在的时候用它，不在则退回 debug 签名 ——
// 模板默认一直是 debug，而 debug 那枚章是**本机自动生成**的：换机 / 重装工具链就变，
// 之前发出去的包便再也覆盖不了（用户只能卸载重装，本机书架与历史一起丢）。
// 放 `key.properties` 而不是写死在这里：密码不进 git（`android/.gitignore` 已忽略它）。
val keystoreProps = Properties()
val keystorePropsFile = rootProject.file("key.properties")
if (keystorePropsFile.exists()) {
    FileInputStream(keystorePropsFile).use { keystoreProps.load(it) }
}
// 只看「文件在不在」不够：手填漏了字段会让签名配置拿到 null，报错还很难懂。
val hasReleaseKey = keystorePropsFile.exists() &&
    !keystoreProps.getProperty("storeFile").isNullOrBlank()

android {
    namespace = "com.azusakano.yamibo_flutter"
    compileSdk = flutter.compileSdkVersion
    // 纯 Dart 工程不需要 NDK；保留 flutter.ndkVersion 会让 AGP 去 Google 下载 NDK。
    // build-tools 由 AGP 9.1 固定为 36.0.0（已手工装到 SDK 目录）。

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 纯 Dart 工程没有自编译 native，不需要 NDK 参与编译；但 AGP **打包时**要用 NDK 里的
    // `llvm-strip` 去掉引擎 .so 的调试符号。这里曾经有一句
    // `jniLibs.keepDebugSymbols += "**/*.so"`，作用是绕开「本机 NDK 是空壳、找不到 llvm-strip」
    // —— 代价是 release 也不 strip，`libflutter.so` 原样 165MB 进包（2026-10-26 实测）。
    // NDK 装好后就去掉了：release 的引擎 165MB → ~10MB，整包 166MB → ~20MB。
    // ⚠ 若哪天 NDK 又被删掉/换机没装，AGP 会报 llvm-strip 缺失；那时装回 NDK，
    //   或临时把 keepDebugSymbols 加回来（但别留着出发布包）。

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.azusakano.yamibo_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 有 key.properties 才创建，避免拿 null 去签名（那种报错信息基本看不懂）
        if (hasReleaseKey) {
            create("release") {
                // storeFile 建议写**绝对路径**：这里 `file()` 是相对 `android/app/` 解析的
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    // 有 key.properties 就用自己那把钥匙；没有（别人 clone / 新环境）就退回 debug。
    val signFor = if (hasReleaseKey) "release" else "debug"

    buildTypes {
        // profile 是 Flutter 插件加的构建类型。**它也用同一把钥匙**：
        // 否则同一台机器上「自己测试的包」与「发出去的包」签名不同、不能互相覆盖，
        // 每次切换都得卸载 —— 而卸载会清掉本机书架、阅读历史与登录态。
        named("profile") {
            signingConfig = signingConfigs.getByName(signFor)
        }
        release {
            signingConfig = signingConfigs.getByName(signFor)
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
