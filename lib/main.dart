import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KioskApp());
}

class KioskApp extends StatelessWidget {
  const KioskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: KioskWebView(),
    );
  }
}

class KioskWebView extends StatefulWidget {
  const KioskWebView({super.key});

  @override
  State<KioskWebView> createState() => _KioskWebViewState();
}

class _KioskWebViewState extends State<KioskWebView> {
  // ✅ Your kiosk web app URL (Vite/Next/etc)
  // final String kioskUrl = "http://192.168.1.161:3000";
  final String kioskUrl = "https://aikiosk-ai-testing-vercel.vercel.app/";

  // ✅ Dart -> Native Android bridge
  static const MethodChannel terminalChannel = MethodChannel(
    "kiosk.stripe.terminal",
  );

  InAppWebViewController? _webViewController;
  bool _isPageLoading = true;
  bool _isPaymentProcessing = false;
  bool _isMicRequesting = false;

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
                colors: [
                  Color(0xFFFFF2E9),
                  Color(0xFFFFF8F4),
                ],
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
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
                setState(() => _isPageLoading = true);
              },
              onLoadStop: (controller, url) {
                if (!mounted) return;
                setState(() => _isPageLoading = false);
              },
              onReceivedError: (controller, request, error) async {
                if (!mounted) return;
                if (request.isForMainFrame != true) return;
                setState(() => _isPageLoading = false);
                await _showPaymentErrorDialog(
                  title: "Page Load Error",
                  message: error.description,
                  icon: Icons.wifi_off,
                );
              },
              onPermissionRequest: (controller, request) async {
                final needsMic = request.resources
                    .contains(PermissionResourceType.MICROPHONE);
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
                    final payload = (args.isNotEmpty) ? _safeMap(args[0]) : {};

                    final type = payload["type"];

                    // ✅ Health ping for debugging
                    if (type == "PING") {
                      return {"ok": true, "pong": true, "platform": "flutter"};
                    }

                    // ✅ Tap-to-Pay entrypoint
                    if (type == "START_TAP_TO_PAY") {
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
                              e.message ?? "Payment failed. Please try again.",
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
                      message: "Unknown command from web app: ${type ?? 'null'}",
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
            _buildLoadingOverlay(),
          ],
        ),
      ),
    );
  }
}
