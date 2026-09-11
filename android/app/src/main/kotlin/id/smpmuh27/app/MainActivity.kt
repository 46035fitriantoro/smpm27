package id.smpmuh27.app

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "id.smpmuh27.app/security"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableSecureFlag" -> {
                    enableSecureFlag()
                    result.success(true)
                }
                "disableSecureFlag" -> {
                    disableSecureFlag()
                    result.success(true)
                }
                "startLockTask" -> {
                    startLockTaskMode()
                    result.success(true)
                }
                "stopLockTask" -> {
                    stopLockTaskMode()
                    result.success(true)
                }
                "blockExit" -> {
                    blockAppExit()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // === SECURITY: Enable FLAG_SECURE on app start ===
        // Blocks screenshot, screen recording, and screen mirroring
        enableSecureFlag()
    }

    // === SECURITY: FLAG_SECURE ===
    // Prevents screenshot, screen recording, and screen mirroring
    private fun enableSecureFlag() {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun disableSecureFlag() {
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    // === SECURITY: Lock Task Mode ===
    // Locks the app to foreground - prevents opening other apps
    private fun startLockTaskMode() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                startLockTask()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopLockTaskMode() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                stopLockTask()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // === SECURITY: Block App Exit ===
    // Moves task to back instead of finishing - prevents back exit
    private fun blockAppExit() {
        try {
            moveTaskToBack(true)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }
}
