package com.example.ai_kiosk_pos

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.nfc.NfcAdapter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.stripe.stripeterminal.Terminal
import com.stripe.stripeterminal.external.callable.Cancelable
import com.stripe.stripeterminal.external.callable.ConnectionTokenCallback
import com.stripe.stripeterminal.external.callable.ConnectionTokenProvider
import com.stripe.stripeterminal.external.callable.PaymentIntentCallback
import com.stripe.stripeterminal.external.callable.ReaderCallback
import com.stripe.stripeterminal.external.callable.TapToPayReaderListener
import com.stripe.stripeterminal.external.callable.TerminalListener
import com.stripe.stripeterminal.external.models.CollectPaymentIntentConfiguration
import com.stripe.stripeterminal.external.models.ConfirmPaymentIntentConfiguration
import com.stripe.stripeterminal.external.models.ConnectionConfiguration
import com.stripe.stripeterminal.external.models.ConnectionStatus
import com.stripe.stripeterminal.external.models.ConnectionTokenException
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration
import com.stripe.stripeterminal.external.models.DisconnectReason
import com.stripe.stripeterminal.external.models.EasyConnectConfiguration
import com.stripe.stripeterminal.external.models.PaymentIntent
import com.stripe.stripeterminal.external.models.PaymentStatus
import com.stripe.stripeterminal.external.models.Reader
import com.stripe.stripeterminal.external.models.TapToPayUxConfiguration
import com.stripe.stripeterminal.external.models.TerminalErrorCode
import com.stripe.stripeterminal.external.models.TerminalException
import com.stripe.stripeterminal.log.LogLevel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity(), TerminalListener {

  // ─── Constants ───────────────────────────────────────────────────────────
  private val channelName = "kiosk.stripe.terminal"
  private val tapToPayTimeoutMs = 120_000L

  // ─── Coroutine scope (cancelled in onDestroy) ─────────────────────────────
  private val activityScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

  // ─── HTTP client (shared, thread-safe) ───────────────────────────────────
  private val httpClient = OkHttpClient.Builder()
    .connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(15, TimeUnit.SECONDS)
    .writeTimeout(15, TimeUnit.SECONDS)
    .build()

  // ─── State ────────────────────────────────────────────────────────────────
  private val mainHandler = Handler(Looper.getMainLooper())
  private val isProcessing = AtomicBoolean(false)
  private val isConnectingReader = AtomicBoolean(false)
  private var pendingResult: MethodChannel.Result? = null
  private var discoveryCancelable: Cancelable? = null
  private var currentPaymentCancelable: Cancelable? = null
  private var terminalBaseUrl: String? = null
  private var paymentTimeoutRunnable: Runnable? = null

  // ─── FIX #1: Track when we intentionally launch Stripe's TTP Activity ────
  // Prevents onUserLeaveHint from cancelling the payment when Stripe's screen opens.
  private var ttpActivityLaunched = false

  // ─── Method channel reference (for sending progress events to Flutter) ────
  private var methodChannel: MethodChannel? = null

  // ─── Permission callbacks ─────────────────────────────────────────────────
  private var pendingPermissionGranted: (() -> Unit)? = null
  private var pendingPermissionDenied: (() -> Unit)? = null
  private var pendingMicrophoneResult: MethodChannel.Result? = null

  private val locationPermissions = arrayOf(
    Manifest.permission.ACCESS_FINE_LOCATION,
    Manifest.permission.ACCESS_COARSE_LOCATION
  )
  private val locationPermissionRequestCode = 1001
  private val microphonePermissionRequestCode = 1002

  // ─── Stripe TTP reader listener ───────────────────────────────────────────
  private val tapToPayReaderListener = object : TapToPayReaderListener {
    override fun onDisconnect(reason: DisconnectReason) {
      Log.w(TAG, "TTP reader disconnected: $reason")
    }
    override fun onReaderReconnectStarted(reader: Reader, cancelReconnect: Cancelable, reason: DisconnectReason) {
      Log.w(TAG, "TTP reader reconnecting: ${reader.serialNumber} ($reason)")
    }
    override fun onReaderReconnectSucceeded(reader: Reader) {
      Log.i(TAG, "TTP reader reconnected: ${reader.serialNumber}")
    }
    override fun onReaderReconnectFailed(reader: Reader) {
      Log.e(TAG, "TTP reader reconnect failed: ${reader.serialNumber}")
    }
  }

  // ─── Flutter engine setup ─────────────────────────────────────────────────
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
    methodChannel = channel
    channel.setMethodCallHandler { call, result ->
      val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
      when (call.method) {
        "startTapToPay"      -> startTapToPay(args, result)
        "prepareTapToPay"    -> prepareTapToPay(args, result)
        "requestMicrophonePermission" -> requestMicrophonePermission(result)
        "getNfcStatus"       -> getNfcStatus(result)
        "openNfcSettings"    -> { openNfcSettings(); result.success(true) }
        else                 -> result.notImplemented()
      }
    }
  }

  // ─── Send real progress event to Flutter ──────────────────────────────────
  /**
   * Sends a real-time progress update to the Flutter dialog.
   * step: 0=Initializing, 1=Connecting, 2=Downloading component, 3=Ready
   */
  private fun sendProgress(step: Int, message: String) {
    mainHandler.post {
      methodChannel?.invokeMethod("onTtpProgress", mapOf("step" to step, "message" to message))
    }
  }

  // ─── Lifecycle ────────────────────────────────────────────────────────────
  override fun onDestroy() {
    super.onDestroy()
    activityScope.cancel()
    httpClient.dispatcher.executorService.shutdown()
    methodChannel = null
  }

  /**
   * FIX #1: Only cancel payment if user ACTUALLY left the app (pressed Home/Recents).
   * When Stripe's TTP Activity opens, Android fires onUserLeaveHint — we skip that.
   */
  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    // If we intentionally launched Stripe's TTP screen, don't cancel
    if (ttpActivityLaunched) {
      Log.d(TAG, "onUserLeaveHint: TTP activity launched — skipping cancel")
      return
    }
    if (!isProcessing.get()) return
    Log.w(TAG, "User left app during payment — cancelling")
    val cancelable = currentPaymentCancelable
    if (cancelable != null && !cancelable.isCompleted) {
      cancelable.cancel(object : com.stripe.stripeterminal.external.callable.Callback {
        override fun onSuccess() = finishWithError("PAYMENT_CANCELLED", "Payment cancelled — app minimized.", null)
        override fun onFailure(e: TerminalException) = finishWithError("PAYMENT_CANCELLED", "Payment cancelled — app minimized.", null)
      })
    } else {
      finishWithError("PAYMENT_CANCELLED", "Payment cancelled — app minimized.", null)
    }
  }

  // ─── Device capability pre-flight ────────────────────────────────────────
  private fun checkDeviceCapability(): Pair<String, String>? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      return "UNSUPPORTED_OS" to "Tap to Pay requires Android 13+. This device runs API ${Build.VERSION.SDK_INT}."
    }
    val nfc = NfcAdapter.getDefaultAdapter(this)
    if (nfc == null) return "NFC_UNSUPPORTED" to "No NFC hardware detected."
    if (!nfc.isEnabled)  return "NFC_DISABLED"   to "NFC is disabled. Enable it in Settings."

    val gms = GoogleApiAvailability.getInstance()
    val gmsResult = gms.isGooglePlayServicesAvailable(this)
    if (gmsResult != ConnectionResult.SUCCESS) {
      return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "Google Play Services unavailable: ${gms.getErrorString(gmsResult)}"
    }

    // SDK v5.2.0: security patch must be within last 12 months
    runCatching {
      val patch = Build.VERSION.SECURITY_PATCH
      val date  = SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(patch)
      val cutoff = Calendar.getInstance().apply { add(Calendar.MONTH, -12) }.time
      if (date != null && date.before(cutoff)) {
        return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "Security patch ($patch) is over 12 months old. Update your device."
      }
    }.onFailure { Log.w(TAG, "Security patch check failed: ${it.message}") }

    if (!BuildConfig.DEBUG) {
      runCatching {
        val devEnabled = Settings.Global.getInt(contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0)
        if (devEnabled != 0) return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "Disable developer options for Tap to Pay in production."
      }.onFailure { Log.w(TAG, "Dev options check failed: ${it.message}") }
    }
    return null
  }

  // ─── prepareTapToPay ─────────────────────────────────────────────────────
  /**
   * Pre-warms the TTP reader: initializes Terminal + connects reader.
   * Sends REAL progress events to Flutter dialog as each step completes.
   * Returns {"status": "READY"} on success (or with a "warning" key on soft failure).
   */
  private fun prepareTapToPay(args: Map<*, *>, result: MethodChannel.Result) {
    val baseUrl    = args["terminalBaseUrl"] as? String
    val locationId = args["locationId"] as? String
    val isSimulated = args["isSimulated"] as? Boolean ?: BuildConfig.DEBUG

    if (baseUrl.isNullOrBlank()) {
      result.error("INVALID_ARGUMENTS", "Missing terminalBaseUrl", null)
      return
    }

    val url = normalizeBaseUrl(baseUrl)
    terminalBaseUrl = url

    // Step 0: Initializing Terminal
    sendProgress(0, "Initializing payment terminal...")

    ensureTerminalInitialized(url) {
      val terminal = Terminal.getInstance()

      if (terminal.connectedReader != null) {
        Log.i(TAG, "prepareTapToPay: reader already connected")
        sendProgress(3, "Reader ready!")
        result.success(mapOf("status" to "READY"))
        return@ensureTerminalInitialized
      }

      if (isConnectingReader.getAndSet(true)) {
        Log.w(TAG, "prepareTapToPay: connection already in progress")
        result.success(mapOf("status" to "READY"))
        return@ensureTerminalInitialized
      }

      ensureLocationPermission(
        onGranted = {
          if (!isLocationServicesEnabled()) {
            isConnectingReader.set(false)
            result.error("LOCATION_SERVICES_DISABLED", "Enable device location.", null)
            return@ensureLocationPermission
          }
          val locId = locationId?.takeIf { it.isNotBlank() }
          if (locId == null) {
            isConnectingReader.set(false)
            result.error("INVALID_ARGUMENTS", "Missing locationId", null)
            return@ensureLocationPermission
          }

          // Step 1: Connecting to reader
          sendProgress(1, "Connecting to payment reader...")

          val config = buildEasyConnectConfig(locId, isSimulated)
          try {
            discoveryCancelable = terminal.easyConnect(config, object : ReaderCallback {
              override fun onSuccess(reader: Reader) {
                isConnectingReader.set(false)
                discoveryCancelable = null
                Log.i(TAG, "prepareTapToPay: connected ${reader.serialNumber}")

                // Step 2: Reader connected — TTP component download may begin
                sendProgress(2, "Downloading payment component...")

                // Apply UX config AFTER reader connects (SDK may reset it otherwise)
                applyTapToPayUxConfig()

                // Step 3: Ready
                sendProgress(3, "Payment reader ready!")
                mainHandler.post { result.success(mapOf("status" to "READY")) }
              }
              override fun onFailure(e: TerminalException) {
                isConnectingReader.set(false)
                discoveryCancelable = null
                Log.w(TAG, "prepareTapToPay: connect failed — ${e.errorMessage}")
                sendProgress(3, "Ready (with warning)")
                // Non-fatal: startTapToPay will retry
                mainHandler.post {
                  result.success(mapOf("status" to "READY", "warning" to (e.errorMessage ?: "Connect failed")))
                }
              }
            })
          } catch (e: Exception) {
            isConnectingReader.set(false)
            discoveryCancelable = null
            Log.w(TAG, "prepareTapToPay: exception — ${e.message}")
            sendProgress(3, "Ready (with warning)")
            mainHandler.post {
              result.success(mapOf("status" to "READY", "warning" to (e.message ?: "Connect failed")))
            }
          }
        },
        onDenied = {
          isConnectingReader.set(false)
          result.error("LOCATION_PERMISSION_DENIED", "Location permission required.", null)
        }
      )
    }
  }

  // ─── startTapToPay ───────────────────────────────────────────────────────
  private fun startTapToPay(args: Map<*, *>, result: MethodChannel.Result) {
    if (isProcessing.getAndSet(true)) {
      result.error("BUSY", "Payment already in progress", null)
      return
    }
    pendingResult = result
    schedulePaymentTimeout()

    checkDeviceCapability()?.let { (code, msg) ->
      finishWithError(code, msg, null)
      return
    }

    val clientSecret = args["clientSecret"] as? String
    val orderId      = args["orderId"]      as? String
    val locationId   = args["locationId"]   as? String
    val baseUrl      = args["terminalBaseUrl"] as? String
    val isSimulated  = args["isSimulated"]  as? Boolean ?: BuildConfig.DEBUG

    if (clientSecret.isNullOrBlank() || baseUrl.isNullOrBlank()) {
      finishWithError("INVALID_ARGUMENTS", "Missing clientSecret or terminalBaseUrl", null)
      return
    }

    val normalizedUrl = normalizeBaseUrl(baseUrl)
    if (terminalBaseUrl != null && terminalBaseUrl != normalizedUrl) {
      Log.w(TAG, "terminalBaseUrl changed — Terminal already initialized with old URL. Restart app to apply.")
    }
    terminalBaseUrl = normalizedUrl

    ensureTerminalInitialized(normalizedUrl) {
      ensureReaderConnected(
        locationId  = locationId,
        isSimulated = isSimulated,
        onConnected = { retrieveAndProcessPayment(clientSecret, orderId) },
        onError     = { e ->
          val msg  = e.errorMessage ?: "Reader error"
          val code = when {
            e.errorCode == TerminalErrorCode.LOCATION_SERVICES_DISABLED -> "LOCATION_SERVICES_DISABLED"
            msg.lowercase().containsAny("aidl", "contactless transaction failed") -> "CONTACTLESS_TRANSACTION_FAILED"
            msg.lowercase().contains("no such reader") -> "TERMINAL_ID_MISMATCH"
            else -> "READER_ERROR"
          }
          val displayMsg = if (code == "TERMINAL_ID_MISMATCH")
            "Terminal ID mismatch. Check the configured reader ID." else msg
          finishWithError(code, displayMsg, e.toString())
        }
      )
    }
  }

  // ─── Terminal initialization ──────────────────────────────────────────────
  private fun ensureTerminalInitialized(baseUrl: String, onReady: () -> Unit) {
    try {
      if (!Terminal.isInitialized()) {
        Terminal.init(applicationContext, LogLevel.VERBOSE, createTokenProvider(baseUrl), this, null)
        Log.i(TAG, "Terminal initialized")
        // Apply initial UX config — will also be applied after reader connects
        applyTapToPayUxConfig()
      }
      onReady()
    } catch (e: Exception) {
      Log.e(TAG, "Terminal init failed: ${e.message}", e)
      finishWithError(classifyErrorCode("INIT_FAILED", e.message, e.toString()), e.message ?: "Terminal init failed", e.toString())
    } catch (e: Error) {
      Log.e(TAG, "Terminal init fatal: ${e.message}", e)
      finishWithError("TAP_TO_PAY_INSECURE_ENVIRONMENT", "Device not compatible with Tap to Pay. ${e.message ?: ""}", e.toString())
    }
  }

  // ─── FIX #3: Apply UX config after reader connects ───────────────────────
  private fun applyTapToPayUxConfig() {
    runCatching {
      Terminal.getInstance().setTapToPayUxConfiguration(
        TapToPayUxConfiguration.Builder()
          .tapZone(TapToPayUxConfiguration.TapZone.Default)
          .build()
      )
      Log.i(TAG, "TapToPayUxConfiguration applied")
    }.onFailure { Log.w(TAG, "TapToPayUxConfiguration failed: ${it.message}") }
  }

  // ─── Connection token provider (OkHttp) ──────────────────────────────────
  private fun createTokenProvider(baseUrl: String): ConnectionTokenProvider {
    return object : ConnectionTokenProvider {
      override fun fetchConnectionToken(callback: ConnectionTokenCallback) {
        activityScope.launch(Dispatchers.IO) {
          try {
            val body = "{}".toRequestBody("application/json".toMediaType())
            val request = Request.Builder()
              .url("$baseUrl/terminal/connection_token")
              .post(body)
              .build()

            val secret = httpClient.newCall(request).execute().use { response ->
              val responseBody = response.body?.string() ?: ""
              if (!response.isSuccessful) throw IllegalStateException("HTTP ${response.code}: $responseBody")
              JSONObject(responseBody).getString("secret")
            }

            withContext(Dispatchers.Main) {
              callback.onSuccess(secret)
            }
          } catch (e: Exception) {
            Log.e(TAG, "Token fetch failed: ${e.message}")
            val msg = when (e) {
              is java.net.UnknownHostException -> "SERVER_UNREACHABLE: Cannot reach payment server. Check network."
              is java.net.ConnectException -> "SERVER_UNREACHABLE: Payment server offline at $baseUrl"
              is java.net.SocketTimeoutException -> "SERVER_UNREACHABLE: Payment server timed out at $baseUrl"
              else -> e.message ?: "Failed to fetch connection token"
            }
            withContext(Dispatchers.Main) {
              callback.onFailure(ConnectionTokenException(msg, e))
            }
          }
        }
      }
    }
  }

  // ─── Reader connection ────────────────────────────────────────────────────
  private fun ensureReaderConnected(
    locationId: String?,
    isSimulated: Boolean,
    onConnected: (Reader) -> Unit,
    onError: (TerminalException) -> Unit
  ) {
    val terminal = Terminal.getInstance()
    terminal.connectedReader?.let {
      Log.d(TAG, "Reusing connected reader: ${it.serialNumber}")
      onConnected(it)
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
    Log.d(TAG, "Connecting fresh reader (simulated=$isSimulated)")
    ensureLocationPermission(
      onGranted = {
        if (!isLocationServicesEnabled()) {
          onError(TerminalException(TerminalErrorCode.LOCATION_SERVICES_DISABLED, "Location services disabled."))
          return@ensureLocationPermission
        }
        val locId = locationId?.takeIf { it.isNotBlank() }
        if (locId == null) {
          onError(TerminalException(TerminalErrorCode.MISSING_REQUIRED_PARAMETER, "Missing locationId"))
          return@ensureLocationPermission
        }

        // FIX #2: If already connecting, report error instead of silently returning
        if (isConnectingReader.getAndSet(true)) {
          Log.w(TAG, "Reader connection already in progress — reporting busy")
          onError(TerminalException(TerminalErrorCode.MISSING_REQUIRED_PARAMETER, "Reader connection already in progress. Please wait."))
          return@ensureLocationPermission
        }

        val config = buildEasyConnectConfig(locId, isSimulated)
        try {
          discoveryCancelable = terminal.easyConnect(config, object : ReaderCallback {
            override fun onSuccess(reader: Reader) {
              isConnectingReader.set(false)
              discoveryCancelable = null
              // Apply UX config after reader connects
              applyTapToPayUxConfig()
              mainHandler.post { onConnected(reader) }
            }
            override fun onFailure(e: TerminalException) {
              isConnectingReader.set(false)
              discoveryCancelable = null
              mainHandler.post { onError(e) }
            }
          })
        } catch (e: Exception) {
          isConnectingReader.set(false)
          discoveryCancelable = null
          mainHandler.post { onError(TerminalException(TerminalErrorCode.MISSING_REQUIRED_PARAMETER, e.message ?: "Connect failed", e)) }
        } catch (e: Error) {
          isConnectingReader.set(false)
          discoveryCancelable = null
          Log.e(TAG, "Fatal error in easyConnect: ${e.message}", e)
          mainHandler.post { finishWithError("TAP_TO_PAY_INSECURE_ENVIRONMENT", "Device not compatible. ${e.message ?: ""}", e.toString()) }
        }
      },
      onDenied = {
        onError(TerminalException(TerminalErrorCode.LOCATION_SERVICES_DISABLED, "Location permission required."))
      }
    )
  }

  private fun buildEasyConnectConfig(locationId: String, isSimulated: Boolean) =
    EasyConnectConfiguration.TapToPayEasyConnectConfiguration(
      DiscoveryConfiguration.TapToPayDiscoveryConfiguration(isSimulated = isSimulated),
      ConnectionConfiguration.TapToPayConnectionConfiguration(locationId, true, tapToPayReaderListener)
    )

  // ─── Payment processing ───────────────────────────────────────────────────
  private fun retrieveAndProcessPayment(clientSecret: String, orderId: String?) {
    val terminal = Terminal.getInstance()
    try {
      terminal.retrievePaymentIntent(clientSecret, object : PaymentIntentCallback {
        override fun onSuccess(paymentIntent: PaymentIntent) {
          try {
            // FIX #1: Mark that we're intentionally launching Stripe's TTP Activity
            ttpActivityLaunched = true

            currentPaymentCancelable = terminal.processPaymentIntent(
              paymentIntent,
              CollectPaymentIntentConfiguration.Builder().build(),
              ConfirmPaymentIntentConfiguration.Builder().build(),
              object : PaymentIntentCallback {
                override fun onSuccess(processed: PaymentIntent) {
                  currentPaymentCancelable = null
                  finishWithSuccess(mapOf(
                    "status"          to "SUCCESS",
                    "paymentIntentId" to processed.id,
                    "amount"          to processed.amount,
                    "currency"        to processed.currency,
                    "orderId"         to orderId
                  ))
                }
                override fun onFailure(e: TerminalException) {
                  currentPaymentCancelable = null
                  finishWithError(classifyErrorCode("PROCESS_FAILED", e.errorMessage, e.toString()), e.errorMessage ?: "Process failed", e.toString())
                }
              }
            )
          } catch (e: Exception) {
            currentPaymentCancelable = null
            finishWithError(classifyErrorCode("PROCESS_FAILED", e.message, e.toString()), e.message ?: "Process failed", e.toString())
          }
        }
        override fun onFailure(e: TerminalException) {
          finishWithError(classifyErrorCode("RETRIEVE_FAILED", e.errorMessage, e.toString()), e.errorMessage ?: "Retrieve failed", e.toString())
        }
      })
    } catch (e: Exception) {
      finishWithError(classifyErrorCode("RETRIEVE_FAILED", e.message, e.toString()), e.message ?: "Retrieve failed", e.toString())
    }
  }

  // ─── Result helpers ───────────────────────────────────────────────────────
  private fun finishWithSuccess(payload: Map<String, Any?>) {
    val result = pendingResult ?: return
    pendingResult = null
    clearPaymentTimeout()
    isProcessing.set(false)
    isConnectingReader.set(false)
    ttpActivityLaunched = false  // FIX #1: reset flag
    discoveryCancelable = null
    currentPaymentCancelable = null
    mainHandler.post { result.success(payload) }
  }

  private fun finishWithError(code: String, message: String, details: String?) {
    val result = pendingResult ?: return
    pendingResult = null
    clearPaymentTimeout()
    isProcessing.set(false)
    isConnectingReader.set(false)
    ttpActivityLaunched = false  // FIX #1: reset flag
    discoveryCancelable = null
    currentPaymentCancelable = null
    mainHandler.post { result.error(code, message, details) }
  }

  // ─── Error classification ─────────────────────────────────────────────────
  private fun classifyErrorCode(default: String, message: String?, details: String?): String {
    val combined = "${message.orEmpty()} ${details.orEmpty()}".lowercase()
    return when {
      combined.containsAny("contactless transaction failed", "aidl", "failed send request to aidl server", "connection error", "no reader") ->
        "CONTACTLESS_TRANSACTION_FAILED"
      combined.containsAny("insecure environment", "hardware keystore", "security patch", "google play", "feature_hardware_keystore", "bootloader", "rooted") ->
        "TAP_TO_PAY_INSECURE_ENVIRONMENT"
      combined.containsAny("server_unreachable", "unknownhostexception", "connectexception", "sockettimeoutexception", "cannot reach payment server", "payment server is offline", "payment server timed out") ->
        "SERVER_UNREACHABLE"
      else -> default
    }
  }

  // ─── Timeout ──────────────────────────────────────────────────────────────
  private fun schedulePaymentTimeout() {
    clearPaymentTimeout()
    paymentTimeoutRunnable = Runnable {
      if (isProcessing.get()) finishWithError("PAYMENT_TIMEOUT", "Payment timed out. Please try again.", null)
    }.also { mainHandler.postDelayed(it, tapToPayTimeoutMs) }
  }

  private fun clearPaymentTimeout() {
    paymentTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
    paymentTimeoutRunnable = null
  }

  // ─── URL normalization ────────────────────────────────────────────────────
  private fun normalizeBaseUrl(url: String) = url.trimEnd('/')

  // ─── Location permission ──────────────────────────────────────────────────
  private fun ensureLocationPermission(onGranted: () -> Unit, onDenied: () -> Unit) {
    if (hasLocationPermission()) { onGranted(); return }
    pendingPermissionGranted = onGranted
    pendingPermissionDenied  = onDenied
    ActivityCompat.requestPermissions(this, locationPermissions, locationPermissionRequestCode)
  }

  private fun hasLocationPermission() = locationPermissions.all {
    ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
  }

  private fun isLocationServicesEnabled(): Boolean {
    val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
    return runCatching {
      lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }.getOrDefault(false)
  }

  // ─── Microphone permission ────────────────────────────────────────────────
  private fun requestMicrophonePermission(result: MethodChannel.Result) {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
      result.success(true); return
    }
    // FIX #5: Don't block on pending request — clear stale state and proceed
    if (pendingMicrophoneResult != null) {
      pendingMicrophoneResult?.success(false)
      pendingMicrophoneResult = null
    }
    pendingMicrophoneResult = result
    ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), microphonePermissionRequestCode)
  }

  // ─── NFC helpers ─────────────────────────────────────────────────────────
  private fun getNfcStatus(result: MethodChannel.Result) {
    val supported = packageManager.hasSystemFeature(PackageManager.FEATURE_NFC)
    val enabled   = NfcAdapter.getDefaultAdapter(this)?.isEnabled == true
    result.success(mapOf("supported" to supported, "enabled" to enabled))
  }

  private fun openNfcSettings() {
    val intent = Intent(Settings.ACTION_NFC_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    if (intent.resolveActivity(packageManager) != null) { startActivity(intent); return }
    startActivity(Intent(Settings.ACTION_WIRELESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
  }

  // ─── Settings helpers ─────────────────────────────────────────────────────
  private fun openAppSettings() {
    startActivity(
      Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    )
  }

  // ─── Permission result ────────────────────────────────────────────────────
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    when (requestCode) {
      locationPermissionRequestCode -> {
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        val onGranted = pendingPermissionGranted.also { pendingPermissionGranted = null }
        val onDenied  = pendingPermissionDenied.also  { pendingPermissionDenied  = null }
        if (granted) onGranted?.invoke() else onDenied?.invoke()
      }
      microphonePermissionRequestCode -> {
        val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (granted) {
          Log.d(TAG, "Microphone permission granted")
          pendingMicrophoneResult?.success(true)
        } else {
          Log.w(TAG, "Microphone permission denied")
          if (!ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.RECORD_AUDIO)) {
            openAppSettings()
          }
          pendingMicrophoneResult?.success(false)
        }
        pendingMicrophoneResult = null
      }
      else -> super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
  }

  // ─── Terminal listener ────────────────────────────────────────────────────
  override fun onConnectionStatusChange(status: ConnectionStatus) { Log.d(TAG, "Connection: $status") }
  override fun onPaymentStatusChange(status: PaymentStatus)       { Log.d(TAG, "Payment: $status") }

  // ─── Companion ────────────────────────────────────────────────────────────
  companion object {
    private const val TAG = "KioskTerminal"
  }
}

// ─── Extension: String.containsAny ───────────────────────────────────────────
private fun String.containsAny(vararg tokens: String) = tokens.any { this.contains(it) }
