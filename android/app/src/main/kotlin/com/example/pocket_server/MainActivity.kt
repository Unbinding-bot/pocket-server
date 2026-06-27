package com.example.pocket_server

import android.content.Context
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipInputStream

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.pocket_server/setup"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "extractBootstrap" -> {
                    val destDir = call.argument<String>("destDir") ?: ""
                    Thread {
                        try {
                            extractZipAsset(
                                "tools/android/bootstrap-aarch64.zip",
                                destDir
                            )
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "EXTRACT_ERROR",
                                    e.message, null)
                            }
                        }
                    }.start()
                }
                "extractDeb" -> {
                    val debAsset = call.argument<String>("asset") ?: ""
                    val destDir  = call.argument<String>("destDir") ?: ""
                    Thread {
                        try {
                            // Copy deb to temp, extract data.tar.xz
                            val tempDeb = File(destDir, "pkg.deb")
                            copyAsset(debAsset, tempDeb.absolutePath)
                            extractDebData(tempDeb.absolutePath, destDir)
                            tempDeb.delete()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "DEB_ERROR",
                                    e.message, null)
                            }
                        }
                    }.start()
                }
                "runCommand" -> {
                    val cmd     = call.argument<String>("cmd") ?: ""
                    val envVars = call.argument<Map<String, String>>("env")
                                  ?: emptyMap()
                    Thread {
                        try {
                            val out = runInEnv(cmd, envVars)
                            runOnUiThread { result.success(out) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "CMD_ERROR",
                                    e.message, null)
                            }
                        }
                    }.start()
                }
                "startServer" -> {
                    val cmd     = call.argument<String>("cmd") ?: ""
                    val envVars = call.argument<Map<String, String>>("env")
                                  ?: emptyMap()
                    Thread {
                        try {
                            val pb = ProcessBuilder(
                                listOf("/system/bin/sh", "-c", cmd))
                            pb.environment().putAll(envVars)
                            pb.redirectErrorStream(true)
                            val proc = pb.start()
                            // Read output line by line and
                            // send back via event channel
                            // (we write to a log file instead)
                            proc.waitFor()
                            runOnUiThread {
                                result.success(proc.exitValue())
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error(
                                    "START_ERROR",
                                    e.message, null)
                            }
                        }
                    }.start()
                }
                "requestBatteryOptimization" -> {
                    requestBatteryOptimization()
                    result.success(null)
                }
                "isBatteryOptimizationDisabled" -> {
                    result.success(
                        isBatteryOptimizationDisabled())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun copyAsset(assetPath: String,
                           destPath: String) {
        assets.open(assetPath).use { inp ->
            FileOutputStream(destPath).use { out ->
                inp.copyTo(out)
            }
        }
    }

    private fun extractZipAsset(assetPath: String,
                                  destDir: String) {
        val dest = File(destDir)
        dest.mkdirs()

        ZipInputStream(assets.open(assetPath)).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val outFile = File(dest, entry.name)
                if (entry.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    if (!outFile.exists()) {
                        FileOutputStream(outFile).use { fos ->
                            zis.copyTo(fos)
                        }
                        // Make executables
                        if (entry.name.contains("/bin/") ||
                            entry.name.endsWith(".so") ||
                            !entry.name.contains(".")) {
                            outFile.setExecutable(true, false)
                        }
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
    }

    private fun extractDebData(debPath: String,
                                destDir: String) {
        // .deb is an ar archive containing data.tar.xz
        // We use the bootstrap's tar to extract it
        val prefix = destDir
        val proc = ProcessBuilder(
            listOf("/system/bin/sh", "-c",
                "cd '$destDir' && " +
                "ar x '$debPath' && " +
                "tar -xf data.tar.xz -C '$destDir' " +
                "  --strip-components=1 2>&1 || " +
                "tar -xJf data.tar.xz -C '$destDir' " +
                "  --strip-components=1 2>&1")
        )
        proc.redirectErrorStream(true)
        proc.directory(File(destDir))
        val p = proc.start()
        p.inputStream.bufferedReader().readText()
        p.waitFor()
    }

    private fun runInEnv(cmd: String,
                          env: Map<String, String>): String {
        val pb = ProcessBuilder(
            listOf("/system/bin/sh", "-c", cmd))
        pb.environment().putAll(env)
        pb.redirectErrorStream(true)
        val p = pb.start()
        val out = p.inputStream.bufferedReader().readText()
        p.waitFor()
        return out
    }

    private fun requestBatteryOptimization() {
        val pm = getSystemService(
            Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(
                packageName)) {
            startActivity(Intent(
                Settings
                .ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
            ).apply {
                data = Uri.parse("package:$packageName")
            })
        }
    }

    private fun isBatteryOptimizationDisabled(): Boolean {
        val pm = getSystemService(
            Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(
            packageName)
    }
}