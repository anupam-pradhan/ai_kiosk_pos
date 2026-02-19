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
import com.example.ai_kiosk_pos.BuildConfig
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.stripe.stripeterminal.Terminal
import com.stripe.stripeterminal.external.callable.Callback
import com.stripe.stripeterminal.external.callable.Cancelable
import com.stripe.stripeterminal.external.callable.ConnectionTokenCallback
import com.stripe.stripeterminal.external.callable.ConnectionTokenProvider
import com.stripe.stripeterminal.external.callable.DiscoveryListener
import com.stripe.stripeterminal.external.callable.PaymentIntentCallback
import com.stripe.stripeterminal.external.callable.ReaderCallback
import com.stripe.stripeterminal.external.callable.TapToPayReaderListener
import com.stripe.stripeterminal.external.callable.TerminalListener
import com.stripe.stripeterminal.external.models.CollectConfiguration
import com.stripe.stripeterminal.external.models.ConnectionConfiguration
import com.stripe.stripeterminal.external.models.ConnectionStatus
import com.stripe.stripeterminal.external.models.ConnectionTokenException
import com.stripe.stripeterminal.external.models.DiscoveryConfiguration
import com.stripe.stripeterminal.external.models.PaymentIntent
import com.stripe.stripeterminal.external.models.PaymentStatus
import com.stripe.stripeterminal.external.models.Reader
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

  private val channelName = "kiosk.stripe.terminal"
  private val tapToPayTimeoutMs = 120_000L
  private val activityScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private val httpClient = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).build()

  private val mainHandler = Handler(Looper.getMainLooper())
  private val isProcessing = AtomicBoolean(false)
  private val isConnectingReader = AtomicBoolean(false)
  
  private var discoveryCancelable: Cancelable? = null
  private var currentPaymentCancelable: Cancelable? = null
  
  private var pendingResult: MethodChannel.Result? = null
  private var terminalBaseUrl: String? = null
  private var paymentTimeoutRunnable: Runnable? = null
  private var ttpActivityLaunched = false

  private var pendingPermissionGranted: (() -> Unit)? = null
  private var pendingPermissionDenied: (() -> Unit)? = null
  private var pendingMicrophoneResult: MethodChannel.Result? = null

  private val locationPermissions = arrayOf(
    Manifest.permission.ACCESS_FINE_LOCATION,
    Manifest.permission.ACCESS_COARSE_LOCATION
  )
  private val locationPermissionRequestCode = 1001
  private val microphonePermissionRequestCode = 1002

  private var methodChannel: MethodChannel? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
    methodChannel = channel
    channel.setMethodCallHandler { call, result ->
      val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
      when (call.method) {
        "startTapToPay"   -> startTapToPay(args, result)
        "prepareTapToPay" -> prepareTapToPay(args, result)
        "requestMicrophonePermission" -> requestMicrophonePermission(result)
        "getNfcStatus"    -> getNfcStatus(result)
        "openNfcSettings" -> { openNfcSettings(); result.success(true) }
        else              -> result.notImplemented()
      }
    }
  }

  private fun sendProgress(step: Int, message: String) {
    mainHandler.post {
      methodChannel?.invokeMethod("onTtpProgress", mapOf("step" to step, "message" to message))
    }
  }

  override fun onDestroy() {
    super.onDestroy()
    activityScope.cancel()
    httpClient.dispatcher.executorService.shutdown()
  }

  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    if (ttpActivityLaunched) return
    if (!isProcessing.get()) return

    // Try to cancel the active collect-payment operation.
    // The cancel callback (or the normal payment callback — whichever fires
    // first) will deliver the result to Flutter via finishWithError/Success.
    // We must NOT call finishWithError here directly because the SDK may
    // still fire its own callback, leading to a double-delivery crash.
    val cancelable = currentPaymentCancelable
    if (cancelable != null && !cancelable.isCompleted) {
      cancelable.cancel(object : Callback {
        // Cancel succeeded → SDK won't fire the payment callback, so we
        // are the ones responsible for delivering the result.
        override fun onSuccess() {
          finishWithError("PAYMENT_CANCELLED", "Payment cancelled — app minimized", null)
        }
        // Cancel failed (payment already completed or confirmed).
        // The normal payment callback will handle the result, so do nothing.
        override fun onFailure(e: TerminalException) {
          Log.d("StripeTerminal", "Cancel after minimize failed (already completed): ${e.message}")
          // Don't call finishWithError — let the payment callback deliver.
        }
      })
    } else {
      // No active cancelable (still in discover/connect phase or already done).
      // Safe to clean up directly.
      finishWithError("PAYMENT_CANCELLED", "Payment cancelled — app minimized", null)
    }
  }

  private fun checkDeviceCapability(): Pair<String, String>? {
    val nfc = NfcAdapter.getDefaultAdapter(this)
    if (nfc == null) return "NFC_UNSUPPORTED" to "No NFC hardware"
    if (!nfc.isEnabled)  return "NFC_DISABLED"   to "NFC disabled"
    val gms = GoogleApiAvailability.getInstance()
    val res = gms.isGooglePlayServicesAvailable(this)
    if (res != ConnectionResult.SUCCESS) return "TAP_TO_PAY_INSECURE_ENVIRONMENT" to "No Google Play Services"
    return null
  }

  private fun prepareTapToPay(args: Map<*, *>, result: MethodChannel.Result) {
    val baseUrl    = args["terminalBaseUrl"] as? String ?: return result.error("INVALID_ARGS", "No URL", null)
    val locationId = args["locationId"] as? String ?: return result.error("INVALID_ARGS", "No LocId", null)
    val isSimulated = args["isSimulated"] as? Boolean ?: BuildConfig.DEBUG

    val url = normalizeBaseUrl(baseUrl)
    terminalBaseUrl = url
    sendProgress(0, "Initializing...")

    ensureTerminalInitialized(url) {
      val terminal = Terminal.getInstance()
      if (terminal.connectedReader != null) {
        sendProgress(3, "Ready!")
        return@ensureTerminalInitialized result.success(mapOf("status" to "READY"))
      }

      if (isConnectingReader.getAndSet(true)) {
        return@ensureTerminalInitialized result.success(mapOf("status" to "READY"))
      }

      ensureLocationPermission(
        onGranted = {
          if (!isLocationServicesEnabled()) {
            isConnectingReader.set(false)
            return@ensureLocationPermission result.error("LOCATION_SERVICES_DISABLED", "Enable Location", null)
          }

          sendProgress(1, "Connecting...")
          
          // v4.x: Use TapToPayDiscoveryConfiguration
          val config = DiscoveryConfiguration.TapToPayDiscoveryConfiguration(isSimulated)

          discoveryCancelable = terminal.discoverReaders(config, object : DiscoveryListener {
            override fun onUpdateDiscoveredReaders(readers: List<Reader>) {
              val reader = readers.firstOrNull()
              if (reader != null) {
                // Cancel discovery to connect
                discoveryCancelable?.cancel(object : Callback {
                  override fun onSuccess() {
                    discoveryCancelable = null
                    connectToReader(reader, locationId, result, true)
                  }
                  override fun onFailure(e: TerminalException) {
                    discoveryCancelable = null
                    connectToReader(reader, locationId, result, true) // Try anyway
                  }
                })
              }
            }
          }, object : Callback {
            override fun onSuccess() {}
            override fun onFailure(e: TerminalException) {
              isConnectingReader.set(false)
              discoveryCancelable = null
              result.success(mapOf("status" to "READY", "warning" to "Discovery failed: ${e.message}"))
            }
          })
        },
        onDenied = {
          isConnectingReader.set(false)
          result.error("LOCATION_PERMISSION_DENIED", "Denied", null)
        }
      )
    }
  }

  /**
   * Returns a stable device identifier. Used as fallback when the discovered
   * reader has no serial number, preventing the Stripe API
   * "empty string for device_serial_number" error.
   */
  private fun deviceId(): String =
    Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: Build.MODEL

  private fun connectToReader(reader: Reader, locationId: String, result: MethodChannel.Result?, isPrepare: Boolean) {
    sendProgress(2, "Downloading...")
    
    // v4.x: Use TapToPayConnectionConfiguration and connectReader (unified method)
    val config = ConnectionConfiguration.TapToPayConnectionConfiguration(
      locationId,
      autoReconnectOnUnexpectedDisconnect = true,
      tapToPayReaderListener = null
    )
    
    Terminal.getInstance().connectReader(reader, config, object : ReaderCallback {
      override fun onSuccess(reader: Reader) {
        isConnectingReader.set(false)
        sendProgress(3, "Ready!")
        result?.success(mapOf("status" to "READY"))
      }
      override fun onFailure(e: TerminalException) {
        isConnectingReader.set(false)
        sendProgress(3, "Ready (warning)")
        if (isPrepare) result?.success(mapOf("status" to "READY", "warning" to e.errorMessage))
      }
    })
  }

  private fun startTapToPay(args: Map<*, *>, result: MethodChannel.Result) {
    if (isProcessing.getAndSet(true)) return result.error("BUSY", "In progress", null)
    pendingResult = result
    schedulePaymentTimeout()
    
    checkDeviceCapability()?.let { (c, m) -> return finishWithError(c, m, null) }
    
    val secret  = args["clientSecret"] as? String
    val locId   = args["locationId"] as? String
    val url     = args["terminalBaseUrl"] as? String
    val orderId = args["orderId"] as? String
    val isSim = args["isSimulated"] as? Boolean ?: false

    if (secret == null || url == null || locId == null) return finishWithError("INVALID_ARGS", "Missing params", null)

    val nUrl = normalizeBaseUrl(url)
    terminalBaseUrl = nUrl

    ensureTerminalInitialized(nUrl) {
      ensureReaderConnected(locId, isSim, {
        retrieveAndProcess(secret, orderId)
      }, { c, m -> finishWithError(c, m, null) })
    }
  }

  private fun ensureReaderConnected(locId: String, isSim: Boolean, onConn: (Reader)->Unit, onErr: (String, String)->Unit) {
    val terminal = Terminal.getInstance()
    terminal.connectedReader?.let { return onConn(it) }

    ensureLocationPermission(
      onGranted = {
        if (!isLocationServicesEnabled()) return@ensureLocationPermission onErr("LOCATION_ERROR", "Location services disabled")
        
        if (isConnectingReader.getAndSet(true)) return@ensureLocationPermission onErr("BUSY", "SDK is busy connecting")

        // Cancel any leftover discovery from a previous attempt
        discoveryCancelable?.let { old ->
          if (!old.isCompleted) old.cancel(object : Callback {
            override fun onSuccess() {}
            override fun onFailure(e: TerminalException) {}
          })
          discoveryCancelable = null
        }

        var readerFoundAndConnecting = false
        
        // v4.x: Use TapToPayDiscoveryConfiguration
        val config = DiscoveryConfiguration.TapToPayDiscoveryConfiguration(isSim)
        
        discoveryCancelable = terminal.discoverReaders(config, object: DiscoveryListener {
          override fun onUpdateDiscoveredReaders(readers: List<Reader>) {
            val r = readers.firstOrNull()
            if (r != null && !readerFoundAndConnecting) {
              readerFoundAndConnecting = true
              discoveryCancelable?.cancel(object: Callback {
                override fun onSuccess() {
                   discoveryCancelable = null
                   // v4.x: Use TapToPayConnectionConfiguration and connectReader
                   val cConfig = ConnectionConfiguration.TapToPayConnectionConfiguration(
                     locId,
                     autoReconnectOnUnexpectedDisconnect = true,
                     tapToPayReaderListener = null
                   )
                   terminal.connectReader(r, cConfig, object: ReaderCallback {
                     override fun onSuccess(reader: Reader) { isConnectingReader.set(false); onConn(reader) }
                     override fun onFailure(e: TerminalException) { isConnectingReader.set(false); onErr("CONNECT_FAILED", e.errorMessage ?: "Connect failed") }
                   })
                }
                override fun onFailure(e: TerminalException) {
                  discoveryCancelable = null
                  // Discovery cancel failed but we still have the reader — try connecting anyway
                  val cConfig = ConnectionConfiguration.TapToPayConnectionConfiguration(
                    locId,
                    autoReconnectOnUnexpectedDisconnect = true,
                    tapToPayReaderListener = null
                  )
                  terminal.connectReader(r, cConfig, object: ReaderCallback {
                    override fun onSuccess(reader: Reader) { isConnectingReader.set(false); onConn(reader) }
                    override fun onFailure(e2: TerminalException) { isConnectingReader.set(false); onErr("CONNECT_FAILED", e2.errorMessage ?: "Connect failed") }
                  })
                }
              })
            }
          }
        }, object: Callback {
          override fun onSuccess() {
            // Discovery completed. If we never found a reader, report error.
            if (!readerFoundAndConnecting) {
              isConnectingReader.set(false)
              discoveryCancelable = null
              onErr("NO_READER_FOUND", "No payment reader found. Please try again.")
            }
          }
          override fun onFailure(e: TerminalException) {
            isConnectingReader.set(false)
            discoveryCancelable = null
            onErr("DISCOVERY_FAILED", e.errorMessage ?: "Discovery failed")
          }
        })

        // Safety timeout: if discovery hangs for more than 15s, abort
        mainHandler.postDelayed({
          if (isConnectingReader.get() && !readerFoundAndConnecting) {
            discoveryCancelable?.let { d ->
              if (!d.isCompleted) d.cancel(object : Callback {
                override fun onSuccess() {}
                override fun onFailure(e: TerminalException) {}
              })
            }
            isConnectingReader.set(false)
            discoveryCancelable = null
            onErr("DISCOVERY_TIMEOUT", "Reader discovery timed out. Please try again.")
          }
        }, 15_000L)
      },
      onDenied = { onErr("LOCATION_ERROR", "Location permission denied") }
    )
  }

  private fun retrieveAndProcess(secret: String, orderId: String?) {
    val terminal = Terminal.getInstance()
    terminal.retrievePaymentIntent(secret, object: PaymentIntentCallback {
      override fun onSuccess(intent: PaymentIntent) {
        ttpActivityLaunched = true
        // v4.x: collectPaymentMethod(intent, callback, config)
        val config = CollectConfiguration.Builder().build()
        currentPaymentCancelable = terminal.collectPaymentMethod(intent, object: PaymentIntentCallback {
          override fun onSuccess(collected: PaymentIntent) {
             currentPaymentCancelable = null
             // v4.x: confirmPaymentIntent (renamed from processPayment)
             terminal.confirmPaymentIntent(collected, object: PaymentIntentCallback {
               override fun onSuccess(processed: PaymentIntent) {
                 finishWithSuccess(mapOf("status" to "SUCCESS", "paymentIntentId" to processed.id, "amount" to processed.amount, "currency" to processed.currency, "orderId" to orderId))
               }
               override fun onFailure(e: TerminalException) {
                 finishWithError("PROCESS_FAILED", e.errorMessage ?: "Process failed", e.toString())
               }
             })
          }
          override fun onFailure(e: TerminalException) {
            currentPaymentCancelable = null
            finishWithError("COLLECT_FAILED", e.errorMessage ?: "Collect failed", e.toString())
          }
        }, config)
      }
      override fun onFailure(e: TerminalException) {
        finishWithError("RETRIEVE_FAILED", e.errorMessage ?: "Retrieve failed", e.toString())
      }
    })
  }

  private fun ensureTerminalInitialized(url: String, onReady: ()->Unit) {
    if (!Terminal.isInitialized()) {
      // Sunmi & some OEMs return "" for Build.SERIAL on API 33+.
      // The Stripe SDK sends that empty string as device_serial_number,
      // which the Stripe API rejects. Setting the system property gives
      // the SDK a non-empty fallback.
      try {
        val serial = Build.SERIAL  // may be "unknown" or ""
        if (serial.isNullOrBlank() || serial == "unknown") {
          val fallbackId = deviceId()
          Log.d("StripeTerminal", "Build.SERIAL is '$serial', injecting fallback id: $fallbackId")
          System.setProperty("ro.serialno", fallbackId)
        }
      } catch (e: Exception) {
        Log.w("StripeTerminal", "Could not check/set device serial: ${e.message}")
      }
      try {
        Terminal.initTerminal(applicationContext, LogLevel.VERBOSE, createTokenProvider(url), this)
      } catch (e: Exception) {
        Log.e("StripeTerminal", "Failed to initialize terminal: ${e.message}")
        // We can't easily propagate this error up from here since onReady is void,
        // but it prevents a hard crash. The subsequent calls will fail gracefully
        // because terminal is not initialized.
      }
    }
    onReady()
  }

  private fun createTokenProvider(url: String) = object : ConnectionTokenProvider {
    override fun fetchConnectionToken(callback: ConnectionTokenCallback) {
      activityScope.launch(Dispatchers.IO) {
        try {
          val body = "{}".toRequestBody("application/json".toMediaType())
          val req = Request.Builder().url("$url/terminal/connection_token").post(body).build()
          val secret = httpClient.newCall(req).execute().use { 
            if (!it.isSuccessful) throw Exception("HTTP ${it.code}")
            JSONObject(it.body?.string() ?: "").getString("secret") 
          }
          withContext(Dispatchers.Main) { callback.onSuccess(secret) }
        } catch (e: Exception) {
          withContext(Dispatchers.Main) { callback.onFailure(ConnectionTokenException(e.message ?: "Failed", e)) }
        }
      }
    }
  }

  /**
   * Atomically grab and clear pendingResult so only the FIRST caller
   * (out of cancel-callback vs. payment-callback) actually delivers.
   */
  private fun takePendingResult(): MethodChannel.Result? {
    val r = pendingResult
    pendingResult = null
    return r
  }

  private fun finishWithSuccess(map: Map<String, Any?>) {
    val r = takePendingResult()
    resetState()
    mainHandler.post { r?.success(map) }
  }

  private fun finishWithError(code: String, msg: String, det: String?) {
    val r = takePendingResult()
    resetState()
    mainHandler.post { r?.error(code, msg, det) }
  }

  private fun resetState() {
    clearPaymentTimeout()
    isProcessing.set(false)
    isConnectingReader.set(false)
    ttpActivityLaunched = false
    discoveryCancelable = null
    currentPaymentCancelable = null
  }

  private fun schedulePaymentTimeout() {
    clearPaymentTimeout()
    paymentTimeoutRunnable = Runnable { if (isProcessing.get()) finishWithError("TIMEOUT", "Timed out", null) }
    mainHandler.postDelayed(paymentTimeoutRunnable!!, tapToPayTimeoutMs)
  }
  
  private fun clearPaymentTimeout() {
    paymentTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
    paymentTimeoutRunnable = null
  }
  
  private fun normalizeBaseUrl(u: String) = u.trimEnd('/')

  private fun ensureLocationPermission(onGranted: ()->Unit, onDenied: ()->Unit) {
    if (locationPermissions.all { ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED }) onGranted()
    else {
      pendingPermissionGranted = onGranted
      pendingPermissionDenied = onDenied
      ActivityCompat.requestPermissions(this, locationPermissions, locationPermissionRequestCode)
    }
  }
  
  private fun isLocationServicesEnabled(): Boolean {
    val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
    return try { lm.isProviderEnabled(LocationManager.GPS_PROVIDER) || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) } catch(e:Exception) { false }
  }

  private fun requestMicrophonePermission(res: MethodChannel.Result) {
    if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) res.success(true)
    else {
      pendingMicrophoneResult?.success(false)
      pendingMicrophoneResult = res
      ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.RECORD_AUDIO), microphonePermissionRequestCode)
    }
  }

  private fun getNfcStatus(res: MethodChannel.Result) {
    val s = packageManager.hasSystemFeature(PackageManager.FEATURE_NFC)
    val e = NfcAdapter.getDefaultAdapter(this)?.isEnabled == true
    res.success(mapOf("supported" to s, "enabled" to e))
  }

  private fun openNfcSettings() {
    startActivity(Intent(Settings.ACTION_NFC_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) 
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    if (requestCode == locationPermissionRequestCode) {
      if (grantResults.all { it == PackageManager.PERMISSION_GRANTED }) pendingPermissionGranted?.invoke() else pendingPermissionDenied?.invoke()
      pendingPermissionGranted = null; pendingPermissionDenied = null
    } else if (requestCode == microphonePermissionRequestCode) {
      pendingMicrophoneResult?.success(grantResults.all { it == PackageManager.PERMISSION_GRANTED })
      pendingMicrophoneResult = null
    } else super.onRequestPermissionsResult(requestCode, permissions, grantResults)
  }

  // v4.x TerminalListener: onUnexpectedReaderDisconnect removed.
  // Disconnect handling now goes through TapToPayReaderListener on the connection config.
  override fun onConnectionStatusChange(status: ConnectionStatus) {}
  override fun onPaymentStatusChange(status: PaymentStatus) {}
}
