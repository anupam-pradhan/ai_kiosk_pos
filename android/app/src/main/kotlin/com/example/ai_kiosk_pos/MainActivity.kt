package com.example.ai_kiosk_pos

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
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
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity(), TerminalListener {
  private val channelName = "kiosk.stripe.terminal"
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

    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
      finishWithError(
        "UNSUPPORTED_OS",
        "Tap to Pay requires Android 13 (API 33) or higher",
        null
      )
      return
    }

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
          val errorCode = if (
            e.errorCode == TerminalErrorCode.LOCATION_SERVICES_DISABLED
          ) {
            "LOCATION_SERVICES_DISABLED"
          } else {
            "READER_ERROR"
          }
          finishWithError(errorCode, e.errorMessage ?: "Reader error", e.toString())
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
      }
      configureTapToPayUx()
      onReady()
    } catch (e: Exception) {
      finishWithError("INIT_FAILED", e.message ?: "Failed to initialize Terminal", e.toString())
    }
  }

  private fun configureTapToPayUx() {
    val brandColor = Color.parseColor("#C2410C")
    val colorScheme = TapToPayUxConfiguration.ColorScheme.Builder()
      .primary(TapToPayUxConfiguration.Color.Value(brandColor))
      .build()
    val config = TapToPayUxConfiguration.Builder()
      .tapZone(TapToPayUxConfiguration.TapZone.Default)
      .darkMode(TapToPayUxConfiguration.DarkMode.SYSTEM)
      .colors(colorScheme)
      .build()
    Terminal.getInstance().setTapToPayUxConfiguration(config)
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
    val connectedReader = terminal.connectedReader
    if (connectedReader != null) {
      onConnected(connectedReader)
      return
    }

    ensureLocationPermission(
      onGranted = {
        if (!isLocationServicesEnabled()) {
          onError(
            TerminalException(
              TerminalErrorCode.LOCATION_SERVICES_DISABLED,
              "Location services disabled. Please enable device location."
            )
          )
          return@ensureLocationPermission
        }
        resolveLocationId(locationId, onError) { resolvedLocationId ->
          if (isConnectingReader.getAndSet(true)) return@resolveLocationId
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
          discoveryCancelable = terminal.easyConnect(
            config,
            object : ReaderCallback {
              override fun onSuccess(reader: Reader) {
                isConnectingReader.set(false)
                mainHandler.post { onConnected(reader) }
              }

              override fun onFailure(e: TerminalException) {
                isConnectingReader.set(false)
                mainHandler.post { onError(e) }
              }
            }
          )
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
    terminal.retrievePaymentIntent(
      clientSecret,
      object : PaymentIntentCallback {
        override fun onSuccess(paymentIntent: PaymentIntent) {
          val collectConfig = CollectPaymentIntentConfiguration.Builder().build()
          val confirmConfig = ConfirmPaymentIntentConfiguration.Builder().build()
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
                finishWithError("PROCESS_FAILED", e.errorMessage ?: "Process failed", e.toString())
              }
            }
          )
        }

        override fun onFailure(e: TerminalException) {
          finishWithError("RETRIEVE_FAILED", e.errorMessage ?: "Retrieve failed", e.toString())
        }
      }
    )
  }

  private fun finishWithSuccess(payload: Map<String, Any?>) {
    val result = pendingResult ?: return
    pendingResult = null
    isProcessing.set(false)
    result.success(payload)
  }

  private fun finishWithError(code: String, message: String, details: String?) {
    val result = pendingResult ?: return
    pendingResult = null
    isProcessing.set(false)
    result.error(code, message, details)
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
