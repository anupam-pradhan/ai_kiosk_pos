import 'package:flutter/material.dart';

/// Enum representing different kiosk modes
enum KioskModeType { kiosk, largeKiosk, pos, mobileKiosk }

/// Model class representing a kiosk mode option
class KioskMode {
  final KioskModeType type;
  final String title;
  final String subtitle;
  final IconData icon;
  final String url;
  final Color color;

  const KioskMode({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.url,
    required this.color,
  });

  /// Creates a copy of this KioskMode with optionally replaced values
  KioskMode copyWith({
    KioskModeType? type,
    String? title,
    String? subtitle,
    IconData? icon,
    String? url,
    Color? color,
  }) {
    return KioskMode(
      type: type ?? this.type,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      icon: icon ?? this.icon,
      url: url ?? this.url,
      color: color ?? this.color,
    );
  }

  @override
  String toString() => 'KioskMode(type: $type, title: $title, url: $url)';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is KioskMode && other.type == type;
  }

  @override
  int get hashCode => type.hashCode;
}
