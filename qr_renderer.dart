import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:qr/qr.dart';
import '../label/label_elements.dart';

class QrRenderer {
  const QrRenderer();
  void paint(Canvas canvas, LabelQr qr) {
    final image = QrImage(QrCode.fromData(data: qr.data, errorCorrectLevel: QrErrorCorrectLevel.M));
    const quiet = 4;
    final modules = image.moduleCount + quiet * 2;
    final dotSize = (qr.size / modules).floor();
    if (dotSize < 1) throw ArgumentError('QR is too small for its data');
    final double inset = ((qr.size - modules * dotSize) / 2).floorToDouble();
    final double startX = qr.x.roundToDouble() + inset;
    final double startY = qr.y.roundToDouble() + inset;
    // Clear the quiet zone when QR codes overlap an image or text.
    canvas.drawRect(Rect.fromLTWH(qr.x, qr.y, qr.size, qr.size),
      Paint()..color = const ui.Color(0xffffffff)..isAntiAlias = false);
    final paint = Paint()..color = const ui.Color(0xff000000)..isAntiAlias = false;
    for (int row = 0; row < image.moduleCount; row++) {
      for (int col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          canvas.drawRect(Rect.fromLTWH(startX + (col + quiet) * dotSize,
            startY + (row + quiet) * dotSize, dotSize.toDouble(), dotSize.toDouble()), paint);
        }
      }
    }
  }
}
