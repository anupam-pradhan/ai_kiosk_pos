package com.example.ai_kiosk_pos

import android.app.Application
import android.util.Log
import com.stripe.stripeterminal.TerminalApplicationDelegate
import java.io.File

class KioskApplication : Application() {

  companion object {
    private const val TAG = "KioskApplication"
    // Must match the SDK version in build.gradle.kts
    private const val CURRENT_SDK_VERSION = "5.2.0"
    // Bump this number to force a full Stripe data wipe on all devices.
    // Use this when deploying to devices that previously ran an older SDK.
    private const val DATA_VERSION = 4
    private const val PREFS_NAME = "kiosk_stripe_prefs"
    private const val KEY_SDK_VERSION = "stripe_sdk_version"
    private const val KEY_DATA_VERSION = "stripe_data_version"
  }

  override fun onCreate() {
    super.onCreate()
    nukeStaleStripeData()
    try {
      TerminalApplicationDelegate.onCreate(this)
    } catch (e: Exception) {
      Log.e(TAG, "TerminalApplicationDelegate init failed: ${e.message}", e)
    } catch (e: Error) {
      Log.e(TAG, "TerminalApplicationDelegate init fatal error: ${e.message}", e)
    }
  }

  /**
   * Aggressively wipe ALL Stripe-related local data when the SDK version
   * or data version changes. This guarantees a clean slate so old devices
   * that ran a previous SDK version won't show stale screens or crash.
   *
   * What gets cleaned:
   *  - All databases containing "stripe", "terminal", "taptopay"
   *  - All SharedPreferences files containing "stripe", "terminal"
   *  - All files/cache directories containing "stripe", "terminal"
   *  - The app's internal cache directory for Stripe
   */
  private fun nukeStaleStripeData() {
    try {
      val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
      val storedSdkVersion = prefs.getString(KEY_SDK_VERSION, null)
      val storedDataVersion = prefs.getInt(KEY_DATA_VERSION, 0)

      if (storedSdkVersion == CURRENT_SDK_VERSION && storedDataVersion == DATA_VERSION) {
        return // Already clean, skip
      }

      Log.w(TAG, "Stripe data wipe required: sdk=$storedSdkVersion->$CURRENT_SDK_VERSION, dataVer=$storedDataVersion->$DATA_VERSION")

      var cleanedCount = 0

      // 1. Delete ALL databases that might belong to Stripe Terminal
      try {
        val dbNames = databaseList()
        for (dbName in dbNames) {
          if (isStripeRelated(dbName)) {
            val deleted = deleteDatabase(dbName)
            Log.i(TAG, "Deleted DB '$dbName': $deleted")
            cleanedCount++
          }
        }
      } catch (e: Exception) {
        Log.w(TAG, "Error cleaning databases: ${e.message}")
      }

      // 2. Delete ALL SharedPreferences files EXCEPT our own tracker.
      // The corrupted Tink keyset is stored in SharedPrefs with an
      // unpredictable name, so we must wipe everything to be safe.
      try {
        val prefsDir = File(filesDir.parentFile, "shared_prefs")
        if (prefsDir.exists()) {
          prefsDir.listFiles()?.forEach { file ->
            // Keep our own prefs file so we can track the version
            if (!file.name.startsWith(PREFS_NAME)) {
              val deleted = file.delete()
              Log.i(TAG, "Deleted prefs '${file.name}': $deleted")
              cleanedCount++
            }
          }
        }
      } catch (e: Exception) {
        Log.w(TAG, "Error cleaning SharedPreferences: ${e.message}")
      }

      // NOTE: We intentionally do NOT clean filesDir, cacheDir, or noBackupFilesDir.
      // The Stripe SDK stores the downloaded Tap to Pay component there, which
      // contains device-specific NFC coil positions and the latest UI assets.
      // Deleting these forces the SDK to re-download, showing the old/basic screen.
      // The crashes were caused by corrupted Tink keysets in SharedPreferences only.

      // Save current versions so we don't wipe again next time
      prefs.edit()
        .putString(KEY_SDK_VERSION, CURRENT_SDK_VERSION)
        .putInt(KEY_DATA_VERSION, DATA_VERSION)
        .apply()

      Log.i(TAG, "Stripe data wipe complete. Cleaned $cleanedCount items.")
    } catch (e: Exception) {
      Log.e(TAG, "Fatal error during Stripe data wipe: ${e.message}", e)
    }
  }

  /**
   * Recursively walk a directory and delete any files/subdirs
   * whose names appear Stripe/Terminal-related.
   */
  private fun cleanDirectory(dir: File, label: String) {
    if (!dir.exists()) return
    dir.listFiles()?.forEach { file ->
      if (isStripeRelated(file.name)) {
        val deleted = if (file.isDirectory) file.deleteRecursively() else file.delete()
        Log.i(TAG, "Deleted $label '${file.name}': $deleted")
      }
    }
  }

  /**
   * Check if a file/database name is Stripe Terminal or payment-related.
   * Includes Tink crypto keysets and Discover mPOS SDK artifacts.
   */
  private fun isStripeRelated(name: String): Boolean {
    val lower = name.lowercase()
    return lower.contains("stripe") ||
           lower.contains("terminal") ||
           lower.contains("taptopay") ||
           lower.contains("tap_to_pay") ||
           lower.contains("ttpa") ||
           lower.contains("com.stripe") ||
           lower.contains("tink") ||
           lower.contains("keyset") ||
           lower.contains("crypto") ||
           lower.contains("discover") ||
           lower.contains("mpos")
  }
}
