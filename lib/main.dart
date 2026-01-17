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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri(kioskUrl)),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            mediaPlaybackRequiresUserGesture: false,
            // recommended for kiosk:
            disableContextMenu: true,
            transparentBackground: false,
          ),
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
                    return {
                      "ok": false,
                      "reason": "MISSING_FIELDS",
                      "missing": missing,
                      "hint":
                          "terminalBaseUrl must be LAN IP like http://192.168.1.161:4242 (not localhost).",
                    };
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

                    await _notifyWebStatus({
                      "ok": true,
                      "type": "PAYMENT_RESULT",
                      "data": nativeRes,
                    });

                    return {"ok": true, "data": nativeRes};
                  } on PlatformException catch (e) {
                    final errorPayload = {
                      "ok": false,
                      "type": "PAYMENT_RESULT",
                      "reason": "NATIVE_ERROR",
                      "code": e.code,
                      "message": e.message,
                      "details": e.details,
                    };
                    await _notifyWebStatus(errorPayload);
                    return {
                      "ok": false,
                      "reason": "NATIVE_ERROR",
                      "code": e.code,
                      "message": e.message,
                      "details": e.details,
                    };
                  } catch (e) {
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

                return {"ok": false, "reason": "UNKNOWN_COMMAND", "type": type};
              },
            );
          },
        ),
      ),
    );
  }
}
