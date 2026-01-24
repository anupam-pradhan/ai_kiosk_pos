import 'package:flutter/material.dart';
import '../models/kiosk_mode.dart';

/// A card widget representing a kiosk mode option
class KioskModeCard extends StatelessWidget {
  final KioskMode mode;
  final VoidCallback onTap;
  final bool useExpanded;

  const KioskModeCard({
    super.key,
    required this.mode,
    required this.onTap,
    this.useExpanded = true,
  });

  @override
  Widget build(BuildContext context) {
    final cardContent = GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints.expand(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
          border: Border.all(color: mode.color.withOpacity(0.1), width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Icon with colored background
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: mode.color.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(mode.icon, color: mode.color, size: 32),
            ),
            const SizedBox(height: 10),
            // Title with consistent size
            Text(
              mode.title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            // Subtitle with consistent size
            Text(
              mode.subtitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.black54,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
    );

    return useExpanded ? Expanded(child: cardContent) : cardContent;
  }
}
