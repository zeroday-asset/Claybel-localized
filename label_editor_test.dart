import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_label_printer_kit/flutter_label_printer_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/label_editor.dart';

class CapturePrinter extends CtLabelPrinter {
  CapturePrinter() : super(config: const CtLabelPrinterConfig(autoConnectEnabled: false));
  LabelDocument? printed;
  @override
  Future<void> printLabel(LabelSource label, {String? description}) async { printed = label.toDocument(); }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('image threshold uses black-zero bit packing with row padding and transparency', () {
    final gray = rgbaToGray(Uint8List.fromList([0,0,0,255, 0,0,0,0, 255,255,255,255]), 3, 1);
    expect(gray, [0,255,255]);
    final item = EditorItem(id: 1, kind: 'image', gray: gray, sourceWidth: 3, sourceHeight: 1, width: 3);
    expect(item.imageBitmap(3, 1), [0x7f]);
    final restored = EditorItem.fromJson(item.toJson()..['width'] = 8);
    expect(restored.gray, gray);
    expect(restored.sourceWidth, 3);
    expect(restored.height, closeTo(8 / 3, .001));
  });

  test('resize and drag stay on the paper and preserve image proportions', () {
    final qr = EditorItem(id: 1, kind: 'qr', x: 390, y: -10, width: 180);
    qr.fit(400, 240);
    expect(qr.x, 220); expect(qr.y, 0);
    qr.width = 500; qr.fit(400, 240);
    expect(qr.width, 240); expect(qr.bounds.right, lessThanOrEqualTo(400));
    final image = EditorItem(id: 2, kind: 'image', sourceWidth: 2, sourceHeight: 1,
      gray: Uint8List.fromList([0,255]), width: 800);
    image.fit(400, 240);
    expect(image.width, 400); expect(image.height, 200);
  });

  testWidgets('drag, resize, save, restore and print use the edited geometry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final printer = CapturePrinter();
    await tester.pumpWidget(MaterialApp(home: LabelEditorPage(printer: printer)));
    await tester.pumpAndSettle();
    var state = tester.state<LabelEditorPageState>(find.byType(LabelEditorPage));
    final qr = state.items.last;
    final originalX = qr.x;
    final rect = tester.getRect(find.byKey(const Key('label-canvas')));
    final scale = rect.width / state.paperWidth;
    final center = rect.topLeft + Offset((qr.x + qr.width / 2) * scale, (qr.y + qr.height / 2) * scale);
    await tester.dragFrom(center, const Offset(-40, 10));
    await tester.pump();
    expect(qr.x, lessThan(originalX));
    final oldWidth = qr.width;
    await tester.drag(find.byKey(const Key('resize-handle')), const Offset(-25, -25));
    await tester.pump();
    expect(qr.width, lessThan(oldWidth));
    // Make this valid for the two-dot QR minimum before printing.
    state.changed(() => qr.width = 100);
    await tester.pump();
    final expectedX = qr.x, expectedY = qr.y, expectedSize = qr.width;
    await tester.runAsync(() => state.saveDraft());
    await tester.ensureVisible(find.text('Print this label'));
    await tester.tap(find.text('Print this label'));
    await tester.pumpAndSettle();
    final printedQr = printer.printed!.children.whereType<LabelQr>().single;
    expect(printedQr.x, expectedX); expect(printedQr.y, expectedY); expect(printedQr.size, expectedSize);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(MaterialApp(home: LabelEditorPage(printer: printer)));
    await tester.pumpAndSettle();
    state = tester.state<LabelEditorPageState>(find.byType(LabelEditorPage));
    expect(state.items.last.x, expectedX); expect(state.items.last.width, expectedSize);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await printer.dispose();
  });

  testWidgets('imported image prints at chosen size and survives saved layout', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = Colors.white);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 8), Paint()..color = Colors.black);
    final image = await tester.runAsync(() => recorder.endRecording().toImage(8,8));
    final data = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    image!.dispose();
    final printer = CapturePrinter();
    await tester.pumpWidget(MaterialApp(home: LabelEditorPage(printer: printer,
      pickImage: () async => data!.buffer.asUint8List())));
    await tester.pumpAndSettle();
    final state = tester.state<LabelEditorPageState>(find.byType(LabelEditorPage));
    await tester.runAsync(() => state.importImage());
    await tester.pumpAndSettle();
    final imported = state.items.last;
    expect(imported.kind, 'image');
    state.changed(() { imported.width = 80; imported.x = 40; imported.y = 40; });
    await tester.pump();
    final bitmap = state.document.children.whereType<LabelImage>().single;
    expect(bitmap.widthPx, 80); expect(bitmap.heightPx, 80); expect(bitmap.x, 40);
    expect(bitmap.monoBitmap.first, 0);
    expect(bitmap.monoBitmap[9], 255);
    await tester.runAsync(() => state.saveDraft());
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(LabelEditorPageState.draftKey), contains('"gray"'));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(MaterialApp(home: LabelEditorPage(printer: printer)));
    await tester.pumpAndSettle();
    final restored = tester.state<LabelEditorPageState>(find.byType(LabelEditorPage)).items.last;
    expect(restored.gray, imported.gray); expect(restored.width, 80);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await printer.dispose();
  });
}
