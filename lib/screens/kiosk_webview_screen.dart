import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../config/app_config.dart';

/// Screen that displays the kiosk web application in a webview
class KioskWebViewScreen extends StatefulWidget {
  const KioskWebViewScreen({super.key, required this.kioskUrl, this.title});

  final String kioskUrl;
  final String? title;

  @override
  State<KioskWebViewScreen> createState() => _KioskWebViewScreenState();
}

class _KioskWebViewScreenState extends State<KioskWebViewScreen>
    with WidgetsBindingObserver {
  static const Duration _tapToPayTimeout = Duration(seconds: 120);
  late final String kioskUrl = widget.kioskUrl;

  // Dart -> Native Android bridge
  static const MethodChannel terminalChannel = MethodChannel(
    "kiosk.stripe.terminal",
  );

  InAppWebViewController? _webViewController;
  bool _isPageLoading = true;
  bool _isPaymentProcessing = false;
  bool _isMicRequesting = false;
  bool _showSplash = true;
  bool _splashMinElapsed = false;
  bool _pageLoaded = false;
  bool _nfcChecked = false;
  bool _hasPageLoadError = false;
  String _pageLoadErrorMessage = '';
  bool _showWebView = true;
  bool _nfcResumeCheckInFlight = false;
  Timer? _retryTimer;
  int _retryCount = 0;

  /// Stream that receives real-time TTP progress events from native.
  /// Native sends: {step: 0-3, message: String}
  final StreamController<Map<String, dynamic>> _ttpProgressController =
      StreamController<Map<String, dynamic>>.broadcast();


  static const Set<String> _fallbackEligibleCodes = {
    "UNSUPPORTED_OS",
    "UNSUPPORTED_DEVICE",
    "NFC_UNSUPPORTED",
    "NFC_DISABLED",
    "LOCATION_SERVICES_DISABLED",
    "TAP_TO_PAY_INSECURE_ENVIRONMENT",
    "READER_ERROR",
    "CONTACTLESS_TRANSACTION_FAILED",
    "PROCESS_FAILED",
    "RETRIEVE_FAILED",
    "INIT_FAILED",
    "INVALID_ARGUMENTS",
    "BASE_URL_CHANGED",
    "PAYMENT_ALREADY_IN_PROGRESS",
    "BUSY",
    "PAYMENT_TIMEOUT",
    "PAYMENT_CANCELLED",
    "SERVER_UNREACHABLE",
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Handle native → Flutter calls on the terminal channel.
    // This receives real-time TTP progress events from MainActivity.
    terminalChannel.setMethodCallHandler((call) async {
      if (call.method == 'onTtpProgress') {
        final args = call.arguments;
        if (args is Map) {
          _ttpProgressController.add(Map<String, dynamic>.from(args));
        }
      }
      return null;
    });

    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      _splashMinElapsed = true;
      _maybeHideSplash();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    terminalChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    terminalChannel.setMethodCallHandler(null);
    _ttpProgressController.close();
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkNfcOnResume();
    }
  }

  void _maybeHideSplash() {
    if (!_showSplash) return;
    if (_splashMinElapsed && _pageLoaded) {
      setState(() => _showSplash = false);
    }
  }

  Map<String, dynamic> _safeMap(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    return <String, dynamic>{};
  }

  Future<void> _notifyWebStatus(Map<String, dynamic> payload) async {
    final controller = _webViewController;
    if (controller == null) return;
    final jsonPayload = jsonEncode(payload);
    await controller.evaluateJavascript(
      source:
          "window.onNativePaymentStatus && window.onNativePaymentStatus($jsonPayload);",
    );
  }

  Map<String, dynamic> _buildFallbackPayload({
    required String code,
    required String reason,
    String? message,
    dynamic details,
  }) {
    return {
      "ok": false,
      "type": "PAYMENT_RESULT",
      "reason": reason,
      "code": code,
      "errorCode": code,
      "message": message,
      "details": details,
      "canFallbackToCard": true,
      "fallbackAction": "USE_EXISTING_CARD_FLOW",
      "exitFlow": true,
    };
  }

  String _normalizeCode(dynamic code) {
    if (code == null) return "";
    return code.toString().trim().toUpperCase();
  }

  Future<void> _injectWebViewFixes(InAppWebViewController controller) async {
    const js = r'''
(function () {
  if (document.getElementById('kiosk-app-fixes')) return;
  const style = document.createElement('style');
  style.id = 'kiosk-app-fixes';
  style.textContent = `
    .safe-top {
      padding-top: 0 !important;
      min-height: 73px !important;
      height: auto !important;
      overflow: visible !important;
    }
  `;
  document.head.appendChild(style);
})();
''';
    await controller.evaluateJavascript(source: js);
  }

  Future<Map<String, dynamic>> _getNfcStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return {"supported": true, "enabled": true};
    }
    try {
      final res = await terminalChannel.invokeMethod<dynamic>("getNfcStatus");
      if (res is Map) return Map<String, dynamic>.from(res);
    } on PlatformException {
      return {"supported": false, "enabled": false};
    }
    return {"supported": false, "enabled": false};
  }

  Future<void> _openNfcSettings() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await terminalChannel.invokeMethod<void>("openNfcSettings");
    } on PlatformException {
      // Best-effort only; ignore failures.
    }
  }

  Future<void> _checkNfcOnStartup() async {
    if (_nfcChecked) return;
    _nfcChecked = true;
    final status = await _getNfcStatus();
    final supported = status["supported"] == true;
    final enabled = status["enabled"] == true;
    if (!supported) {
      await _notifyWebStatus({
        "ok": false,
        "type": "DEVICE_CAPABILITY",
        "code": "NFC_UNSUPPORTED",
        "errorCode": "NFC_UNSUPPORTED",
        "reason": "NFC_UNSUPPORTED",
        "canFallbackToCard": true,
        "fallbackAction": "USE_EXISTING_CARD_FLOW",
        "exitFlow": true,
      });
      return;
    }
    if (!enabled) {
      await _showNfcDisabledDialog();
    }
  }

  Future<void> _checkNfcOnResume() async {
    if (_nfcResumeCheckInFlight) return;
    _nfcResumeCheckInFlight = true;
    try {
      final status = await _getNfcStatus();
      final supported = status["supported"] == true;
      final enabled = status["enabled"] == true;
      if (!supported) {
        await _notifyWebStatus({
          "ok": false,
          "type": "DEVICE_CAPABILITY",
          "code": "NFC_UNSUPPORTED",
          "errorCode": "NFC_UNSUPPORTED",
          "reason": "NFC_UNSUPPORTED",
          "canFallbackToCard": true,
          "fallbackAction": "USE_EXISTING_CARD_FLOW",
          "exitFlow": true,
        });
        return;
      }
      if (!enabled) {
        await _showNfcDisabledDialog();
      }
    } finally {
      _nfcResumeCheckInFlight = false;
    }
  }

  Future<void> _showNfcDisabledDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.nfc, color: Colors.orange),
              SizedBox(width: 8),
              Expanded(child: Text("Enable NFC")),
            ],
          ),
          content: const Text(
            "Tap to Pay needs NFC. Please enable NFC in settings to continue.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _openNfcSettings();
              },
              child: const Text("Open Settings"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showPaymentErrorDialog({
    required String title,
    required String message,
    IconData icon = Icons.error_outline,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(icon, color: Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(child: Text(title)),
            ],
          ),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text("OK"),
            ),
          ],
        );
      },
    );
  }

  /// Shows an animated progress dialog while the TTP component downloads.
  /// Progress steps are driven by REAL native events (onTtpProgress) from MainActivity.
  /// A safety fallback timer advances steps if native events are delayed.
  Future<void> _showTtpPrepareDialog({
    required String terminalBaseUrl,
    required String locationId,
    required bool isSimulated,
  }) async {
    if (!mounted) return;

    // Steps map native step index → display message
    // Native sends step 0=Initializing, 1=Connecting, 2=Downloading, 3=Ready
    const stepMessages = [
      'Initializing payment terminal...',
      'Connecting to payment reader...',
      'Downloading payment component...',
      'Payment reader ready!',
    ];

    int currentStep = 0;
    String currentMessage = stepMessages[0];
    bool isDone = false;
    StateSetter? dialogSetState;

    // Start native prepare call in parallel (60s timeout for slow component downloads)
    Map<dynamic, dynamic> prepareResult = {'status': 'UNKNOWN'};
    final prepareFuture = terminalChannel
        .invokeMethod('prepareTapToPay', {
          'terminalBaseUrl': terminalBaseUrl,
          'locationId': locationId,
          'isSimulated': isSimulated,
        })
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () => {'status': 'TIMEOUT'},
        )
        .then((res) {
          if (res is Map) prepareResult = res;
          return res;
        })
        .catchError((e) {
          prepareResult = {'status': 'ERROR', 'error': e.toString()};
          return prepareResult;
        });

    // Listen to REAL native progress events
    final progressSub = _ttpProgressController.stream.listen((event) {
      if (isDone || dialogSetState == null) return;
      final step = event['step'] as int? ?? currentStep;
      final msg = event['message'] as String? ?? stepMessages[math.min(step, stepMessages.length - 1)];
      dialogSetState!(() {
        currentStep = math.min(step, stepMessages.length - 1);
        currentMessage = msg;
      });
    });

    // Safety fallback: if native events are slow, advance steps every 8s
    // This only kicks in if native hasn't sent an event for that step yet
    final fallbackTimer = Stream.periodic(const Duration(seconds: 8), (i) => i)
        .take(stepMessages.length - 1)
        .listen((i) {
      if (isDone || dialogSetState == null) return;
      final nextStep = i + 1;
      if (nextStep > currentStep) {
        // Only advance if native hasn't already moved us past this step
        dialogSetState!(() {
          currentStep = nextStep;
          currentMessage = stepMessages[nextStep];
        });
      }
    });

    // Show compact dialog (matching existing _buildLoadingOverlay style)
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          dialogSetState = setState;
          const brandColor = Color(0xFFC2410C);
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFF2E9), Color(0xFFFFF8F4)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 12,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            valueColor: AlwaysStoppedAnimation<Color>(brandColor),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: Text(
                              currentMessage,
                              key: ValueKey(currentMessage),
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 160,
                      child: LinearProgressIndicator(
                        value: (currentStep + 1) / stepMessages.length,
                        backgroundColor: const Color(0xFFF5D8C9),
                        valueColor: const AlwaysStoppedAnimation<Color>(brandColor),
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    try {
      // Wait for native call to complete
      await prepareFuture;
    } finally {
      isDone = true;
      progressSub.cancel();
      fallbackTimer.cancel();
    }

    // specific status check to avoid showing "Ready!" on failure
    final isSuccess = prepareResult['status'] == 'READY';
    
    // Show "Ready!" briefly then close ONLY if successful
    if (isSuccess && dialogSetState != null) {
      dialogSetState!(() {
        currentStep = stepMessages.length - 1;
        currentMessage = stepMessages.last;
      });
      await Future.delayed(const Duration(milliseconds: 700));
    }

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _showPaymentSuccessDialog({
    String? last4,
    String? cardBrand,
    int? amountCents,
    String? currency,
  }) async {
    if (!mounted) return;
    // Format amount: cents -> readable string e.g. "$12.50"
    String amountStr = '';
    if (amountCents != null && amountCents > 0) {
      final dollars = amountCents / 100.0;
      final currencySymbol = (currency ?? 'usd').toLowerCase() == 'usd' ? '\$' : (currency?.toUpperCase() ?? '');
      amountStr = '$currencySymbol${dollars.toStringAsFixed(2)}';
    }
    final cardStr = (last4 != null && last4.isNotEmpty)
        ? '${cardBrand != null ? '${_formatBrand(cardBrand)} ' : ''}ending in $last4'
        : '';
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.check_circle_outline, color: Colors.green),
              SizedBox(width: 8),
              Expanded(child: Text('Payment Successful')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified, color: Colors.green, size: 48),
              const SizedBox(height: 12),
              if (amountStr.isNotEmpty)
                Text(
                  amountStr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 28,
                    color: Colors.green,
                  ),
                ),
              if (cardStr.isNotEmpty) ...
                [
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.credit_card, size: 16, color: Colors.black54),
                      const SizedBox(width: 4),
                      Text(
                        cardStr,
                        style: const TextStyle(color: Colors.black54, fontSize: 13),
                      ),
                    ],
                  ),
                ],
              const SizedBox(height: 8),
              const Text(
                'Your order will be prepared shortly.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  String _formatBrand(String brand) {
    switch (brand.toLowerCase()) {
      case 'visa': return 'Visa';
      case 'mastercard': return 'Mastercard';
      case 'amex': return 'Amex';
      case 'discover': return 'Discover';
      case 'jcb': return 'JCB';
      case 'unionpay': return 'UnionPay';
      default: return brand[0].toUpperCase() + brand.substring(1);
    }
  }

  Widget _buildLoadingOverlay() {
    if (_showSplash) return const SizedBox.shrink();

    // Only show for page load, payment processing (after TTP prep), or mic request
    final show = _isPageLoading || _isPaymentProcessing || _isMicRequesting;
    if (!show) return const SizedBox.shrink();

    final label = _isMicRequesting
        ? "Requesting microphone..."
        : (_isPaymentProcessing ? "Processing payment..." : "Loading...");
    
    final sublabel = "Please wait a moment";
    const brandColor = Color(0xFFC2410C);
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.18),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFFFF2E9), Color(0xFFFFF8F4)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 12,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.restaurant_menu, color: brandColor, size: 28),
                const SizedBox(height: 12),
                const SizedBox(
                  width: 160,
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    valueColor: AlwaysStoppedAnimation<Color>(brandColor),
                    backgroundColor: Color(0xFFF5D8C9),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  sublabel,
                  style: const TextStyle(color: Colors.black54, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInAppSplash() {
    if (!_showSplash) return const SizedBox.shrink();
    const bgColor = Color(0xFFF3F4F6);
    const logoColor = Color(0xFFC2410C);
    return Positioned.fill(
      child: Container(
        color: bgColor,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              CircleAvatar(
                radius: 46,
                backgroundColor: logoColor,
                child: Icon(Icons.restaurant, color: Colors.white, size: 42),
              ),
              SizedBox(height: 18),
              _DotLoader(color: logoColor),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageLoadError() {
    if (!_hasPageLoadError) return const SizedBox.shrink();
    const brandColor = Color(0xFFC2410C);
    return Positioned.fill(
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off, color: brandColor, size: 56),
              const SizedBox(height: 16),
              const Text(
                "We could not load the kiosk",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _pageLoadErrorMessage.isEmpty
                    ? "Please check the connection and try again."
                    : _pageLoadErrorMessage,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54, fontSize: 14),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _hasPageLoadError = false;
                    _pageLoadErrorMessage = '';
                    _isPageLoading = true;
                    _showWebView = false;
                  });
                  _webViewController?.reload();
                },
                child: const Text("Retry"),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Offstage(
              offstage: !_showWebView,
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(kioskUrl)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  mediaPlaybackRequiresUserGesture: false,
                  allowsInlineMediaPlayback: true,
                  disableContextMenu: true,
                  transparentBackground: false,
                ),
                onLoadStart: (controller, url) {
                  if (!mounted) return;
                  _pageLoaded = false;
                  setState(() {
                    _isPageLoading = true;
                    _hasPageLoadError = false;
                    _pageLoadErrorMessage = '';
                  });
                },
                onLoadStop: (controller, url) {
                  if (!mounted) return;
                  _pageLoaded = true;
                  _maybeHideSplash();
                  setState(() {
                    _isPageLoading = false;
                    _showWebView = true;
                  });
                  _checkNfcOnStartup();
                  _injectWebViewFixes(controller);
                },
                onReceivedServerTrustAuthRequest: (controller, challenge) async {
                  return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
                },
                onReceivedError: (controller, request, error) async {
                  if (!mounted) return;
                  // Ignore subframe errors or non-critical resource failures
                  if (request.isForMainFrame != true) return;

                  _pageLoaded = true;
                  _maybeHideSplash();

                  // Auto-retry logic for connection issues
                  if (_retryCount < 5) {
                    _retryTimer?.cancel();
                    _retryTimer = Timer(const Duration(seconds: 5), () {
                      if (mounted) {
                        _webViewController?.reload();
                      }
                    });
                    _retryCount++;
                  }

                  setState(() {
                    _isPageLoading = false;
                    _hasPageLoadError = true;
                    _pageLoadErrorMessage = "${error.description}\n(Retrying $_retryCount/5...)";
                    _showWebView = false;
                  });
                },
                onPermissionRequest: (controller, request) async {
                  final needsMic = request.resources.contains(
                    PermissionResourceType.MICROPHONE,
                  );
                  if (needsMic) {
                    debugPrint(
                      "WebView permission request: ${request.resources}",
                    );
                    if (mounted) {
                      setState(() => _isMicRequesting = true);
                    }
                    final granted = await terminalChannel.invokeMethod<bool>(
                      "requestMicrophonePermission",
                    );
                    if (mounted) {
                      setState(() => _isMicRequesting = false);
                    }
                    if (granted != true) {
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.DENY,
                      );
                    }
                  }
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                  controller.addJavaScriptHandler(
                    handlerName: "kioskBridge",
                    callback: (args) async {
                      final payload = (args.isNotEmpty)
                          ? _safeMap(args[0])
                          : {};
                      final type = payload["type"];

                      // Health ping for debugging
                      if (type == "PING") {
                        return {
                          "ok": true,
                          "pong": true,
                          "platform": "flutter",
                        };
                      }

                      // Tap-to-Pay entrypoint
                      if (type == "START_TAP_TO_PAY") {
                        if (_isPaymentProcessing) {
                          final busyPayload = _buildFallbackPayload(
                            code: "PAYMENT_ALREADY_IN_PROGRESS",
                            reason: "BUSY",
                            message: "A payment is already in progress.",
                          );
                          await _notifyWebStatus(busyPayload);
                          return busyPayload;
                        }

                        final nfcStatus = await _getNfcStatus();
                        final nfcSupported = nfcStatus["supported"] == true;
                        final nfcEnabled = nfcStatus["enabled"] == true;
                        if (!nfcSupported) {
                          final errorPayload = _buildFallbackPayload(
                            code: "NFC_UNSUPPORTED",
                            reason: "NFC_UNSUPPORTED",
                            message:
                                "This device does not support NFC Tap to Pay.",
                          );
                          await _notifyWebStatus(errorPayload);
                          return errorPayload;
                        }
                        if (!nfcEnabled) {
                          await _showNfcDisabledDialog();
                          final errorPayload = _buildFallbackPayload(
                            code: "NFC_DISABLED",
                            reason: "NFC_DISABLED",
                            message:
                                "NFC is disabled. Enable NFC to use Tap to Pay.",
                          );
                          await _notifyWebStatus(errorPayload);
                          return errorPayload;
                        }

                        final amount = payload["amount"];
                        final currency = payload["currency"];
                        final orderId = payload["orderId"];
                        final paymentIntentId = payload["paymentIntentId"];
                        final clientSecret = payload["clientSecret"];
                        final terminalBaseUrl = payload["terminalBaseUrl"];
                        final locationId = payload["locationId"];

                        // Validate required fields
                        final missing = <String, bool>{
                          "amount": amount == null,
                          "currency": currency == null,
                          "orderId": orderId == null,
                          "paymentIntentId": paymentIntentId == null,
                          "clientSecret": clientSecret == null,
                          "terminalBaseUrl": terminalBaseUrl == null,
                          "locationId": locationId == null,
                        };

                        final hasMissing = missing.values.any((v) => v == true);
                        if (hasMissing) {
                          await _showPaymentErrorDialog(
                            title: "Payment Error",
                            message:
                                "Payment request is missing required fields.",
                          );
                          return {
                            "ok": false,
                            "reason": "MISSING_FIELDS",
                            "missing": missing,
                            "hint":
                                "terminalBaseUrl must be LAN IP like http://192.168.1.161:4242 (not localhost).",
                          };
                        }

                        if (mounted) {
                          setState(() {
                            // Don't set _isPaymentProcessing=true yet; waiting for prep dialog
                            _isPaymentProcessing = false;
                          });
                        }
                        // Show animated progress dialog while TTP component downloads
                        await _showTtpPrepareDialog(
                          terminalBaseUrl: terminalBaseUrl as String,
                          locationId: locationId as String,
                          isSimulated: AppConfig.isTapToPaySimulated,
                        );
                        if (mounted) {
                          setState(() {
                            _isPaymentProcessing = true;
                          });
                        }
                        try {
                          final nativeRes = await terminalChannel
                              .invokeMethod("startTapToPay", {
                                "amount": amount,
                                "currency": currency,
                                "orderId": orderId,
                                "paymentIntentId": paymentIntentId,
                                "clientSecret": clientSecret,
                                "terminalBaseUrl": terminalBaseUrl,
                                "locationId": locationId,
                                "isSimulated": AppConfig.isTapToPaySimulated,
                              })
                              .timeout(_tapToPayTimeout);

                          await _notifyWebStatus({
                            "ok": true,
                            "type": "PAYMENT_RESULT",
                            "data": nativeRes,
                          });

                          final resMap = nativeRes is Map
                              ? Map<String, dynamic>.from(nativeRes as Map)
                              : <String, dynamic>{};
                          await _showPaymentSuccessDialog(
                            last4: resMap['last4'] as String?,
                            cardBrand: resMap['cardBrand'] as String?,
                            amountCents: resMap['amount'] as int?,
                            currency: resMap['currency'] as String?,
                          );

                          return {"ok": true, "data": nativeRes};
                        } on TimeoutException {
                          final timeoutPayload = _buildFallbackPayload(
                            code: "PAYMENT_TIMEOUT",
                            reason: "TIMEOUT",
                            message:
                                "Tap to Pay timed out. Continue with card flow.",
                          );
                          await _notifyWebStatus(timeoutPayload);
                          return timeoutPayload;
                        } on PlatformException catch (e) {
                          final normalizedCode = _normalizeCode(e.code);

                          // Device capability errors: silently redirect to card flow
                          // (no dialog shown — same behavior as old APK)
                          const silentFallbackCodes = {
                            "NFC_UNSUPPORTED",
                            "NFC_DISABLED",
                            "UNSUPPORTED_OS",
                            "UNSUPPORTED_DEVICE",
                            // Covers: no TEE, outdated security patch, rooted device,
                            // developer options on, hardware keystore missing
                            "TAP_TO_PAY_INSECURE_ENVIRONMENT",
                            "READER_ERROR",
                            "CONTACTLESS_TRANSACTION_FAILED",
                            "LOCATION_SERVICES_DISABLED",
                            "LOCATION_PERMISSION_DENIED",
                            "SERVER_UNREACHABLE",
                            "PAYMENT_CANCELLED",
                            "BUSY",
                            "PAYMENT_TIMEOUT",
                            "NO_READER_FOUND",
                            "DISCOVERY_TIMEOUT",
                            "CONNECT_FAILED",
                          };

                          final isSilentFallback = silentFallbackCodes
                              .contains(normalizedCode);

                          final errorPayload = _buildFallbackPayload(
                            code: normalizedCode.isEmpty
                                ? "NATIVE_ERROR"
                                : normalizedCode,
                            reason: normalizedCode.isEmpty
                                ? "NATIVE_ERROR"
                                : normalizedCode,
                            message: e.message ??
                                "Tap to Pay unavailable. Use card flow.",
                            details: e.details,
                          );

                          // Only show dialog for truly unexpected errors
                          if (!isSilentFallback) {
                            await _showPaymentErrorDialog(
                              title: "Payment Failed",
                              message: e.message ??
                                  "Payment failed. Please try again.",
                            );
                          }

                          await _notifyWebStatus(errorPayload);
                          return errorPayload;
                        } catch (e) {
                          if (mounted) {
                            setState(() => _isPaymentProcessing = false);
                          }
                          await _showPaymentErrorDialog(
                            title: "Payment Failed",
                            message: "Payment failed. ${e.toString()}",
                          );
                          await _notifyWebStatus({
                            "ok": false,
                            "type": "PAYMENT_RESULT",
                            "reason": "NATIVE_ERROR",
                            "message": e.toString(),
                            "canFallbackToCard": true,
                            "fallbackAction": "USE_EXISTING_CARD_FLOW",
                            "exitFlow": true,
                          });
                          return {
                            "ok": false,
                            "reason": "NATIVE_ERROR",
                            "message": e.toString(),
                            "canFallbackToCard": true,
                            "fallbackAction": "USE_EXISTING_CARD_FLOW",
                            "exitFlow": true,
                          };
                        } finally {
                          if (mounted) {
                            setState(() {
                              _isPaymentProcessing = false;
                            });
                          }
                        }
                      }

                      await _showPaymentErrorDialog(
                        title: "Unsupported Request",
                        message:
                            "Unknown command from web app: ${type ?? 'null'}",
                        icon: Icons.help_outline,
                      );
                      return {
                        "ok": false,
                        "reason": "UNKNOWN_COMMAND",
                        "type": type,
                      };
                    },
                  );
                },
              ),
            ),
            _buildLoadingOverlay(),
            _buildInAppSplash(),
            _buildPageLoadError(),
          ],
        ),
      ),
    );
  }
}

class _DotLoader extends StatefulWidget {
  const _DotLoader({required this.color});

  final Color color;

  @override
  State<_DotLoader> createState() => _DotLoaderState();
}

class _DotLoaderState extends State<_DotLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (index) {
        final start = index * 0.2;
        final end = start + 0.6;
        final animation = CurvedAnimation(
          parent: _controller,
          curve: Interval(start, end, curve: Curves.easeInOut),
        );
        return FadeTransition(
          opacity: animation,
          child: Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        );
      }),
    );
  }
}
