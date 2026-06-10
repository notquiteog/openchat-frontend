import 'dart:io';
import 'package:image/image.dart' as img;

// Composes assets/images/logo_unread.png: the app logo with an iOS-red badge
// dot in the top-right corner, used as the tray icon while unread > 0.
void main() {
  final src = img.decodePng(File('assets/images/logo.png').readAsBytesSync())!;
  final out = src.clone();
  final r = (src.width * 0.12).round();
  final cx = src.width - r - (src.width * 0.03).round();
  final cy = r + (src.height * 0.03).round();
  // White outline ring so the dot reads on any tray background.
  img.fillCircle(out, x: cx, y: cy, radius: r + (r * 0.22).round(),
      color: img.ColorRgba8(255, 255, 255, 255));
  img.fillCircle(out, x: cx, y: cy, radius: r,
      color: img.ColorRgba8(255, 59, 48, 255));
  File('assets/images/logo_unread.png').writeAsBytesSync(img.encodePng(out));
  stdout.writeln(
    'wrote assets/images/logo_unread.png ${out.width}x${out.height}',
  );
}
