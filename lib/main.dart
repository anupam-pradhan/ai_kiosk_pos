import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'animated_splash.dart';

class AppConfig {
  static String get appMode =>
      dotenv.env['APP_MODE'] ??
      const String.fromEnvironment('APP_MODE', defaultValue: 'test');

  static String get kioskUrlLive =>
      dotenv.env['KIOSK_URL_LIVE'] ??
      const String.fromEnvironment(
        'KIOSK_URL_LIVE',
        defaultValue: 'https://aikiosk-ai-testing-vercel.vercel.app/',
      );

  static String get kioskUrlTest =>
      dotenv.env['KIOSK_URL_TEST'] ??
      const String.fromEnvironment(
        'KIOSK_URL_TEST',
        defaultValue: 'http://192.168.1.161:3000',
      );

  static bool get isLive => appMode.toLowerCase() == 'live';
  static String get kioskUrl => isLive ? kioskUrlLive : kioskUrlTest;
  static bool get isTapToPaySimulated {
    final raw =
        dotenv.env['TAP_TO_PAY_SIMULATED'] ??
        const String.fromEnvironment('TAP_TO_PAY_SIMULATED');
    if (raw.isEmpty) return !isLive;
    return raw.toLowerCase() == 'true';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const KioskApp());
}

class KioskApp extends StatelessWidget {
  const KioskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AnimatedSplashScreen(
        duration: const Duration(milliseconds: 2000),
        child: const KioskWebView(),
      ),
    );
  }
}

class KioskWebView extends StatefulWidget {
  const KioskWebView({super.key});

  @override
  State<KioskWebView> createState() => _KioskWebViewState();
}

class _KioskWebViewState extends State<KioskWebView>
    with WidgetsBindingObserver {
  // ✅ Your kiosk web app URL (Vite/Next/etc)
  final String kioskUrl = AppConfig.kioskUrl;

  // ✅ Dart -> Native Android bridge
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      _splashMinElapsed = true;
      _maybeHideSplash();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  Future<void> _showPaymentSuccessDialog(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.check_circle_outline, color: Colors.green),
              SizedBox(width: 8),
              Expanded(child: Text("Payment Successful")),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified, color: Colors.green, size: 48),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              const Text(
                "Your order will be prepared shortly.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54, fontSize: 13),
              ),
            ],
          ),
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

  Widget _buildLoadingOverlay() {
    if (_showSplash) return const SizedBox.shrink();
    final show = _isPageLoading || _isPaymentProcessing || _isMicRequesting;
    if (!show) return const SizedBox.shrink();
    final label = _isMicRequesting
        ? "Requesting microphone..."
        : (_isPaymentProcessing ? "Processing payment..." : "Loading...");
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
                const SizedBox(height: 4),
                const Text(
                  "Please wait a moment",
                  style: TextStyle(color: Colors.black54, fontSize: 13),
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
                  // recommended for kiosk:
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
                },
                onReceivedError: (controller, request, error) async {
                  if (!mounted) return;
                  if (request.isForMainFrame != true) return;
                  _pageLoaded = true;
                  _maybeHideSplash();
                  setState(() {
                    _isPageLoading = false;
                    _hasPageLoadError = true;
                    _pageLoadErrorMessage = error.description;
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
                      // Web calls: window.flutter_inappwebview.callHandler("kioskBridge", payload)
                      final payload = (args.isNotEmpty)
                          ? _safeMap(args[0])
                          : {};

                      final type = payload["type"];

                      // ✅ Health ping for debugging
                      if (type == "PING") {
                        return {
                          "ok": true,
                          "pong": true,
                          "platform": "flutter",
                        };
                      }

                      // ✅ Tap-to-Pay entrypoint
                      if (type == "START_TAP_TO_PAY") {
                        final nfcStatus = await _getNfcStatus();
                        final nfcSupported = nfcStatus["supported"] == true;
                        final nfcEnabled = nfcStatus["enabled"] == true;
                        if (!nfcSupported) {
                          final errorPayload = {
                            "ok": false,
                            "type": "PAYMENT_RESULT",
                            "code": "NFC_UNSUPPORTED",
                            "errorCode": "NFC_UNSUPPORTED",
                            "reason": "NFC_UNSUPPORTED",
                          };
                          await _notifyWebStatus(errorPayload);
                          return errorPayload;
                        }
                        if (!nfcEnabled) {
                          final errorPayload = {
                            "ok": false,
                            "type": "PAYMENT_RESULT",
                            "code": "NFC_DISABLED",
                            "errorCode": "NFC_DISABLED",
                            "reason": "NFC_DISABLED",
                          };
                          await _notifyWebStatus(errorPayload);
                          return errorPayload;
                        }

                        final amount = payload["amount"];
                        final currency = payload["currency"];
                        final orderId = payload["orderId"];

                        // These 3 are REQUIRED for real Stripe Terminal flow:
                        final paymentIntentId = payload["paymentIntentId"];
                        final clientSecret = payload["clientSecret"];
                        final terminalBaseUrl = payload["terminalBaseUrl"];
                        final locationId = payload["locationId"];

                        // Validate (fail fast with clear reason)
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
                          setState(() => _isPaymentProcessing = true);
                        }
                        try {
                          // Forward everything to native Android (Kotlin)
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
                              });

                          if (mounted) {
                            setState(() => _isPaymentProcessing = false);
                          }

                          await _notifyWebStatus({
                            "ok": true,
                            "type": "PAYMENT_RESULT",
                            "data": nativeRes,
                          });

                          await _showPaymentSuccessDialog(
                            "Payment successful.",
                          );

                          return {"ok": true, "data": nativeRes};
                        } on PlatformException catch (e) {
                          if (mounted) {
                            setState(() => _isPaymentProcessing = false);
                          }
                          final errorPayload = {
                            "ok": false,
                            "type": "PAYMENT_RESULT",
                            "reason": "NATIVE_ERROR",
                            "code": e.code,
                            "message": e.message,
                            "details": e.details,
                          };
                          await _showPaymentErrorDialog(
                            title: "Payment Failed",
                            message:
                                e.message ??
                                "Payment failed. Please try again.",
                          );
                          await _notifyWebStatus(errorPayload);
                          return {
                            "ok": false,
                            "reason": "NATIVE_ERROR",
                            "code": e.code,
                            "message": e.message,
                            "details": e.details,
                          };
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
                          });
                          return {
                            "ok": false,
                            "reason": "NATIVE_ERROR",
                            "message": e.toString(),
                          };
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
