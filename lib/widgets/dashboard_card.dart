import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class DashboardCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;

  const DashboardCard({
    super.key,
    required this.title,
    required this.value,
    required this.color,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final compact = width <= 390;
    final iosTight =
        width <= 430 && (kIsWeb || defaultTargetPlatform == TargetPlatform.iOS);

    final card = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFFE5E7EB),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: EdgeInsets.all(iosTight ? 12 : (compact ? 14 : 16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: iosTight ? 44 : (compact ? 48 : 54),
            width: iosTight ? 44 : (compact ? 48 : 54),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              color: color,
              size: iosTight ? 22 : (compact ? 24 : 28),
            ),
          ),
          SizedBox(height: iosTight ? 10 : (compact ? 12 : 16)),
          Text(
            value,
            style: TextStyle(
              fontSize: iosTight ? 22 : (compact ? 24 : 28),
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
          SizedBox(height: iosTight ? 6 : (compact ? 8 : 10)),
          Expanded(
            child: Text(
              title,
              maxLines: iosTight ? 3 : (compact ? 4 : 3),
              overflow: TextOverflow.fade,
              style: TextStyle(
                fontSize: iosTight ? 12 : (compact ? 13 : 14),
                height: iosTight ? 1.2 : 1.3,
                color: const Color(0xFF374151),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    return onTap == null
        ? card
        : InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: card,
          );
  }
}
