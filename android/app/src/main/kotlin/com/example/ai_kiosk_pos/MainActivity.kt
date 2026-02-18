package com.example.ai_kiosk_pos

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.location.LocationManager
import android.nfc.NfcAdapter
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.example.ai_kiosk_pos.BuildConfig
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.ConnectionResult
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.stripe.stripeterminal.Terminal
import com.stripe.stripeterminal.external.callable.ConnectionTokenCallback
import com.stripe.stripeterminal.external.callable.ConnectionTokenProvider
import com.stripe.stripeterminal.external.callable.PaymentIntentCallback
import com.stripe.stripeterminal.external.callable.ReaderCallback
import com.stripe.stripeterminal.external.callable.TapToPayReaderListener
import com.stripe.stripeterminal.external.callable.TerminalListener
import com.stripe.stripeterminal.external.callable.Cancelable
import com.stripe.stripeterminal.external.models.CollectPaymentIntentConfiguration
import com.stripe.stripeterminal.external.models.ConnectionConfiguration
import com.stripe.stripeterminal.external.models.ConnectionTokenException
import com.stripe.stripeterminal.external.models.ConnectionStatus
import com.stripe.stripeterminal.external.models.ConfirmPaymentIntentConfiguration
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration
import com.stripe.stripeterminal.external.models.EasyConnectConfiguration
import com.stripe.stripeterminal.external.models.DisconnectReason
import com.stripe.stripeterminal.external.models.PaymentIntent
import com.stripe.stripeterminal.external.models.PaymentStatus
import com.stripe.stripeterminal.external.models.Reader
import com.stripe.stripeterminal.external.models.TerminalErrorCode
import com.stripe.stripeterminal.external.models.TerminalException
import com.stripe.stripeterminal.external.models.TapToPayUxConfiguration
import com.stripe.stripeterminal.log.LogLevel
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity(), TerminalListener {
  private val channelName = "kiosk.stripe.terminal"
  private val tapToPayTimeoutMs = 120_000L
  private val mainHandler = Handler(Looper.getMainLooper())
  private val isProcessing = AtomicBoolean(false)
  private val isConnectingReader = AtomicBoolean(false)
  private var pendingResult: MethodChannel.Result? = null
  private var discoveryCancelable: Cancelable? = null
  private var terminalBaseUrl: String? = null
  private var pendingPermissionGranted: (() -> Unit)? = null
  private var pendingPermissionDenied: (() -> Unit)? = null
  private val tapToPayReaderListener = object : TapToPayReaderListener {
    override fun onDisconnect(reason: DisconnectReason) {
      Log.w("KioskTerminal", "Tap to Pay reader disconnected: $reason")
    }

    override fun onReaderReconnectStarted(
      reader: Reader,
      cancelReconnect: Cancelable,
      reason: DisconnectReason
    ) {
      Log.w("KioskTerminal", "Tap to Pay reader reconnecting: ${reader.serialNumber} ($reason)")
    }

    override fun onReaderReconnectSucceeded(reader: Reader) {
      Log.i("KioskTerminal", "Tap to Pay reader reconnected: ${reader.serialNumber}")
    }

    override fun onReaderReconnectFailed(reader: Reader) {
      Log.e("KioskTerminal", "Tap to Pay reader reconnect failed: ${reader.serialNumber}")
    }
  }

  private val locationPermissions = arrayOf(
    Manifest.permission.ACCESS_FINE_LOCATION,
    Manifest.permission.ACCESS_COARSE_LOCATION
  )

  private val locationPermissionRequestCode = 1001
  private val microphonePermissionRequestCode = 1002
  private val microphonePermission = Manifest.permission.RECORD_AUDIO
  private var pendingMicrophoneResult: MethodChannel.Result? = null
  private var paymentTimeoutRunnable: Runnable? = null

  /**
   * Pre-flight check: verify the device meets all Tap to Pay requirements
   * BEFORE touching the Stripe SDK. Returns null if OK, or an error pair (code, message).
   */
  private fun checkDeviceCapability(): Pair<String, String>? {
    // 1. Android version
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      return "UNSUPPORTED_OS" to "Tap to Pay requires Android 13 (API 33) or higher. This device runs Android ${Build.VERSION.SDK_INT}."
    }

    // 2. NFC hardware
    val nfcAdapter = NfcAdapter.getDefaultAdapter(this)
    if (nfcAdapter == null) {
      return "NFC_UNSUPPORTED" to "This device does not have NFC hardware. Tap to Pay is not available."
    }
    if (!nfcAdapter.isEnabled) {
      return "NFC_DISABLED" to "NFC is disabled. Please enable NFC in device settings to use Tap to Pay."
    }

    // 3. Google Play Services
    val gmsAvailability = GoogleApiAvailability.getInstance()
    val gmsResult = gmsAvailability.isGooglePlayServicesAvailable(this)
    if (gmsResult != ConnectionResult.SUCCESS) {
      val gmsMessage = gmsAvailability.getErrorString(gmsResult)
      Log.e("KioskTerminal", "Google Play Services not available: $gmsMessage (code=$gmsResult)")
      return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "Google Play Services required for Tap to Pay. Status: $gmsMessage"
    }

    // 4. Security patch date (must be within last 12 months)
    try {
      val patchDateStr = Build.VERSION.SECURITY_PATCH // format: "YYYY-MM-DD"
      val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
      val patchDate = sdf.parse(patchDateStr)
      if (patchDate != null) {
        val cutoff = Calendar.getInstance().apply { add(Calendar.MONTH, -12) }.time
        if (patchDate.before(cutoff)) {
          Log.w("KioskTerminal", "Security patch too old: $patchDateStr")
          return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "Security patch ($patchDateStr) is over 12 months old. Please update your device."
        }
      }
    } catch (e: Exception) {
      Log.w("KioskTerminal", "Could not check security patch date: ${e.message}")
    }

    // 5. Developer options (production only)
    if (!BuildConfig.DEBUG) {
      try {
        val devEnabled = Settings.Global.getInt(
          contentResolver,
          Settings.Global.DEVELOPMENT_SETTINGS_ENABLED,
          0
        )
        if (devEnabled != 0) {
          Log.w("KioskTerminal", "Developer options are enabled in production")
          return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "Developer options must be disabled for Tap to Pay in production."
        }
      } catch (e: Exception) {
        Log.w("KioskTerminal", "Could not check developer options: ${e.message}")
      }
    }

    return null // All checks passed
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "startTapToPay" -> {
            val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
            startTapToPay(args, result)
          }
          "requestMicrophonePermission" -> {
            requestMicrophonePermission(result)
          }
          "getNfcStatus" -> {
            getNfcStatus(result)
          }
          "openNfcSettings" -> {
            openNfcSettings()
            result.success(true)
          }
          else -> result.notImplemented()
        }
      }
  }

  private fun startTapToPay(args: Map<*, *>, result: MethodChannel.Result) {
    if (isProcessing.getAndSet(true)) {
      result.error("BUSY", "Payment already in progress", null)
      return
    }

    pendingResult = result
    schedulePaymentTimeout()

    // Pre-flight device capability check — catches all issues before touching Stripe SDK
    val capabilityError = checkDeviceCapability()
    if (capabilityError != null) {
      finishWithError(capabilityError.first, capabilityError.second, null)
      return
    }

    // NFC checks are now handled by checkDeviceCapability() above

    val clientSecret = args["clientSecret"] as? String
    val orderId = args["orderId"] as? String
    val locationId = args["locationId"] as? String
    val baseUrl = args["terminalBaseUrl"] as? String
    val isSimulated = args["isSimulated"] as? Boolean ?: BuildConfig.DEBUG

    if (clientSecret.isNullOrBlank() || baseUrl.isNullOrBlank()) {
      finishWithError("INVALID_ARGUMENTS", "Missing clientSecret or terminalBaseUrl", null)
      return
    }

    val normalizedBaseUrl = normalizeBaseUrl(baseUrl)
    if (terminalBaseUrl != null && terminalBaseUrl != normalizedBaseUrl) {
      finishWithError("BASE_URL_CHANGED", "terminalBaseUrl changed after initialization", null)
      return
    }
    terminalBaseUrl = normalizedBaseUrl

    ensureTerminalInitialized(normalizedBaseUrl) {
      ensureReaderConnected(
        locationId,
        isSimulated,
        onConnected = { _ ->
          retrieveAndProcessPayment(clientSecret, orderId)
        },
        onError = { e ->
          val readerErrorMessage = e.errorMessage ?: "Reader error"
          val errorCode = if (
            e.errorCode == TerminalErrorCode.LOCATION_SERVICES_DISABLED
          ) {
            "LOCATION_SERVICES_DISABLED"
          } else if (
            readerErrorMessage.lowercase().contains("aidl") ||
            readerErrorMessage.lowercase().contains("contactless transaction failed")
          ) {
            "CONTACTLESS_TRANSACTION_FAILED"
          } else if (
            readerErrorMessage.lowercase().contains("no such reader")
          ) {
            "TERMINAL_ID_MISMATCH"
          } else {
            "READER_ERROR"
          }
          val errorMessage = if (errorCode == "TERMINAL_ID_MISMATCH") {
            "Terminal ID mismatch. Please check the configured terminal reader ID."
          } else {
            readerErrorMessage
          }
          finishWithError(errorCode, errorMessage, e.toString())
        }
      )
    }
  }

  private fun ensureTerminalInitialized(baseUrl: String, onReady: () -> Unit) {
    try {
      if (!Terminal.isInitialized()) {
        Terminal.init(
          applicationContext,
          LogLevel.VERBOSE,
          createTokenProvider(baseUrl),
          this,
          null
        )
        Log.i("KioskTerminal", "Terminal initialized successfully")
        // Note: TapToPayUxConfiguration is NOT set here intentionally.
        // The SDK auto-detects the device's NFC coil position from its
        // built-in database, showing the correct tap indicator per device.
      }
      onReady()
    } catch (e: Exception) {
      Log.e("KioskTerminal", "Terminal init Exception: ${e.message}", e)
      val code = classifyErrorCode("INIT_FAILED", e.message, e.toString())
      finishWithError(code, e.message ?: "Failed to initialize Terminal", e.toString())
    } catch (e: Error) {
      // Catches NoClassDefFoundError, ExceptionInInitializerError, etc. on old devices
      Log.e("KioskTerminal", "Terminal init fatal Error: ${e.message}", e)
      finishWithError(
        "TAP_TO_PAY_INSECURE_ENVIRONMENT",
        "This device is not compatible with Tap to Pay. ${e.message ?: ""}",
        e.toString()
      )
    }
  }

  private fun createTokenProvider(baseUrl: String): ConnectionTokenProvider {
    return object : ConnectionTokenProvider {
      override fun fetchConnectionToken(callback: ConnectionTokenCallback) {
        Thread {
          try {
            val url = URL("$baseUrl/terminal/connection_token")
            val conn = (url.openConnection() as HttpURLConnection).apply {
              requestMethod = "POST"
              doOutput = true
              setRequestProperty("Content-Type", "application/json")
            }
            val payload = "{}".toByteArray(StandardCharsets.UTF_8)
            conn.outputStream.use { it.write(payload) }
            val responseCode = conn.responseCode
            val body = if (responseCode in 200..299) {
              conn.inputStream.bufferedReader().use { it.readText() }
            } else {
              conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
            }
            if (responseCode !in 200..299) {
              throw IllegalStateException("HTTP $responseCode $body")
            }
            val json = JSONObject(body)
            val secret = json.getString("secret")
            mainHandler.post { callback.onSuccess(secret) }
          } catch (e: Exception) {
            val exception = ConnectionTokenException(
              e.message ?: "Failed to fetch connection token",
              e
            )
            mainHandler.post { callback.onFailure(exception) }
          }
        }.start()
      }
    }
  }

  private fun ensureReaderConnected(
    locationId: String?,
    isSimulated: Boolean,
    onConnected: (Reader) -> Unit,
    onError: (TerminalException) -> Unit
  ) {
    val terminal = Terminal.getInstance()

    // Reuse existing connection for speed. Stale data is already cleaned
    // by KioskApplication.nukeStaleStripeData() on version change.
    val connectedReader = terminal.connectedReader
    if (connectedReader != null) {
      Log.d("KioskTerminal", "Reusing already-connected reader: ${connectedReader.serialNumber}")
      onConnected(connectedReader)
      return
    }

    connectFreshReader(terminal, locationId, isSimulated, onConnected, onError)
  }

  private fun connectFreshReader(
    terminal: Terminal,
    locationId: String?,
    isSimulated: Boolean,
    onConnected: (Reader) -> Unit,
    onError: (TerminalException) -> Unit
  ) {
    Log.d("KioskTerminal", "Starting fresh reader connection (simulated=$isSimulated)")
    ensureLocationPermission(
      onGranted = {
        if (!isLocationServicesEnabled()) {
          Log.w("KioskTerminal", "Location services disabled")
          onError(
            TerminalException(
              TerminalErrorCode.LOCATION_SERVICES_DISABLED,
              "Location services disabled. Please enable device location."
            )
          )
          return@ensureLocationPermission
        }
        resolveLocationId(locationId, onError) { resolvedLocationId ->
          if (isConnectingReader.getAndSet(true)) {
            Log.w("KioskTerminal", "Reader connection already in progress")
            return@resolveLocationId
          }
          val discoveryConfig = DiscoveryConfiguration.TapToPayDiscoveryConfiguration(
            isSimulated = isSimulated
          )
          val connectionConfig = ConnectionConfiguration.TapToPayConnectionConfiguration(
            resolvedLocationId,
            true,
            tapToPayReaderListener
          )
          val config = EasyConnectConfiguration.TapToPayEasyConnectConfiguration(
            discoveryConfig,
            connectionConfig
          )
          try {
            discoveryCancelable = terminal.easyConnect(
              config,
              object : ReaderCallback {
                override fun onSuccess(reader: Reader) {
                  isConnectingReader.set(false)
                  discoveryCancelable = null
                  mainHandler.post { onConnected(reader) }
                }

                override fun onFailure(e: TerminalException) {
                  isConnectingReader.set(false)
                  discoveryCancelable = null
                  mainHandler.post { onError(e) }
                }
              }
            )
          } catch (e: Exception) {
            isConnectingReader.set(false)
            discoveryCancelable = null
            mainHandler.post {
              onError(
                TerminalException(
                  TerminalErrorCode.MISSING_REQUIRED_PARAMETER,
                  e.message ?: "Failed to connect Tap to Pay reader",
                  e
                )
              )
            }
          } catch (e: Error) {
            // Catches fatal errors like NoClassDefFoundError on incompatible devices
            isConnectingReader.set(false)
            discoveryCancelable = null
            Log.e("KioskTerminal", "Fatal error during easyConnect: ${e.message}", e)
            mainHandler.post {
              finishWithError(
                "TAP_TO_PAY_INSECURE_ENVIRONMENT",
                "This device is not compatible with Tap to Pay. ${e.message ?: ""}",
                e.toString()
              )
            }
          }
        }
      },
      onDenied = {
        onError(
          TerminalException(
            TerminalErrorCode.LOCATION_SERVICES_DISABLED,
            "Location permission required to discover readers"
          )
        )
      }
    )
  }

  private fun resolveLocationId(
    locationId: String?,
    onError: (TerminalException) -> Unit,
    onReady: (String) -> Unit
  ) {
    if (!locationId.isNullOrBlank()) {
      onReady(locationId)
      return
    }

    onError(
      TerminalException(
        TerminalErrorCode.MISSING_REQUIRED_PARAMETER,
        "Missing locationId for Tap to Pay"
      )
    )
  }

  private fun retrieveAndProcessPayment(clientSecret: String, orderId: String?) {
    val terminal = Terminal.getInstance()
    try {
      terminal.retrievePaymentIntent(
        clientSecret,
        object : PaymentIntentCallback {
          override fun onSuccess(paymentIntent: PaymentIntent) {
            val collectConfig = CollectPaymentIntentConfiguration.Builder().build()
            val confirmConfig = ConfirmPaymentIntentConfiguration.Builder().build()
            try {
              terminal.processPaymentIntent(
                paymentIntent,
                collectConfig,
                confirmConfig,
                object : PaymentIntentCallback {
                  override fun onSuccess(processedIntent: PaymentIntent) {
                    finishWithSuccess(
                      mapOf(
                        "status" to "SUCCESS",
                        "paymentIntentId" to processedIntent.id,
                        "amount" to processedIntent.amount,
                        "currency" to processedIntent.currency,
                        "orderId" to orderId
                      )
                    )
                  }

                  override fun onFailure(e: TerminalException) {
                    val code = classifyErrorCode("PROCESS_FAILED", e.errorMessage, e.toString())
                    finishWithError(code, e.errorMessage ?: "Process failed", e.toString())
                  }
                }
              )
            } catch (e: Exception) {
              val code = classifyErrorCode("PROCESS_FAILED", e.message, e.toString())
              finishWithError(code, e.message ?: "Process failed", e.toString())
            }
          }

          override fun onFailure(e: TerminalException) {
            val code = classifyErrorCode("RETRIEVE_FAILED", e.errorMessage, e.toString())
            finishWithError(code, e.errorMessage ?: "Retrieve failed", e.toString())
          }
        }
      )
    } catch (e: Exception) {
      val code = classifyErrorCode("RETRIEVE_FAILED", e.message, e.toString())
      finishWithError(code, e.message ?: "Retrieve failed", e.toString())
    }
  }

  private fun finishWithSuccess(payload: Map<String, Any?>) {
    val result = pendingResult ?: return
    pendingResult = null
    clearPaymentTimeout()
    isProcessing.set(false)
    isConnectingReader.set(false)
    discoveryCancelable = null
    mainHandler.post { result.success(payload) }
  }

  private fun finishWithError(code: String, message: String, details: String?) {
    val result = pendingResult ?: return
    pendingResult = null
    clearPaymentTimeout()
    isProcessing.set(false)
    isConnectingReader.set(false)
    discoveryCancelable = null
    mainHandler.post { result.error(code, message, details) }
  }

  private fun classifyErrorCode(
    defaultCode: String,
    message: String?,
    details: String?
  ): String {
    val combined = "${message ?: ""} ${details ?: ""}".lowercase()
    if (
      combined.contains("contactless transaction failed") ||
      combined.contains("aidl") ||
      combined.contains("failed send request to aidl server") ||
      combined.contains("connection error") ||
      combined.contains("no reader")
    ) {
      return "CONTACTLESS_TRANSACTION_FAILED"
    }
    if (
      combined.contains("insecure environment") ||
      combined.contains("hardware keystore") ||
      combined.contains("security patch") ||
      combined.contains("google play") ||
      combined.contains("feature_hardware_keystore") ||
      combined.contains("bootloader") ||
      combined.contains("rooted")
    ) {
      return "TAP_TO_PAY_INSECURE_ENVIRONMENT"
    }
    return defaultCode
  }

  private fun schedulePaymentTimeout() {
    clearPaymentTimeout()
    paymentTimeoutRunnable = Runnable {
      if (!isProcessing.get()) return@Runnable
      finishWithError(
        "PAYMENT_TIMEOUT",
        "Payment request timed out. Please try again.",
        null
      )
    }
    mainHandler.postDelayed(paymentTimeoutRunnable!!, tapToPayTimeoutMs)
  }

  private fun clearPaymentTimeout() {
    paymentTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
    paymentTimeoutRunnable = null
  }

  private fun normalizeBaseUrl(baseUrl: String): String {
    return if (baseUrl.endsWith("/")) baseUrl.dropLast(1) else baseUrl
  }

  private fun ensureLocationPermission(onGranted: () -> Unit, onDenied: () -> Unit) {
    if (hasLocationPermission()) {
      onGranted()
      return
    }

    pendingPermissionGranted = onGranted
    pendingPermissionDenied = onDenied
    ActivityCompat.requestPermissions(this, locationPermissions, locationPermissionRequestCode)
  }

  private fun requestMicrophonePermission(result: MethodChannel.Result) {
    if (ContextCompat.checkSelfPermission(this, microphonePermission) ==
      PackageManager.PERMISSION_GRANTED
    ) {
      result.success(true)
      return
    }

    if (pendingMicrophoneResult != null) {
      result.success(false)
      return
    }

    pendingMicrophoneResult = result
    ActivityCompat.requestPermissions(
      this,
      arrayOf(microphonePermission),
      microphonePermissionRequestCode
    )
  }

  private fun getNfcStatus(result: MethodChannel.Result) {
    val supported = packageManager.hasSystemFeature(PackageManager.FEATURE_NFC)
    val enabled = NfcAdapter.getDefaultAdapter(this)?.isEnabled == true
    result.success(
      mapOf(
        "supported" to supported,
        "enabled" to enabled
      )
    )
  }

  private fun openAppSettings() {
    val intent = Intent(
      Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
      Uri.fromParts("package", packageName, null)
    ).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    startActivity(intent)
  }

  private fun openNfcSettings() {
    val intent = Intent(Settings.ACTION_NFC_SETTINGS).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    if (intent.resolveActivity(packageManager) != null) {
      startActivity(intent)
      return
    }
    val fallback = Intent(Settings.ACTION_WIRELESS_SETTINGS).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    startActivity(fallback)
  }

  private fun hasLocationPermission(): Boolean {
    return locationPermissions.all { permission ->
      ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED
    }
  }

  private fun isLocationServicesEnabled(): Boolean {
    val locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
    return try {
      locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
        locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    } catch (e: Exception) {
      false
    }
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray
  ) {
    if (requestCode == locationPermissionRequestCode) {
      val granted = grantResults.isNotEmpty() &&
        grantResults.all { it == PackageManager.PERMISSION_GRANTED }
      val onGranted = pendingPermissionGranted
      val onDenied = pendingPermissionDenied
      pendingPermissionGranted = null
      pendingPermissionDenied = null
      if (granted) {
        onGranted?.invoke()
      } else {
        onDenied?.invoke()
      }
      return
    }
    if (requestCode == microphonePermissionRequestCode) {
      val granted = grantResults.isNotEmpty() &&
        grantResults.all { it == PackageManager.PERMISSION_GRANTED }
      if (granted) {
        Log.d("KioskPermissions", "Microphone permission granted")
        pendingMicrophoneResult?.success(true)
      } else {
        Log.w("KioskPermissions", "Microphone permission denied")
        val canAskAgain = ActivityCompat.shouldShowRequestPermissionRationale(
          this,
          microphonePermission
        )
        if (!canAskAgain) {
          Log.w("KioskPermissions", "Microphone permission permanently denied; opening settings")
          openAppSettings()
        }
        pendingMicrophoneResult?.success(false)
      }
      pendingMicrophoneResult = null
      return
    }

    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
  }

  override fun onConnectionStatusChange(status: ConnectionStatus) {
    Log.d("KioskTerminal", "Connection status: $status")
  }

  override fun onPaymentStatusChange(status: PaymentStatus) {
    Log.d("KioskTerminal", "Payment status: $status")
  }

}
