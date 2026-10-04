import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_label_printer_kit/flutter_label_printer_kit.dart';
import 'package:flutter_label_printer_kit/src/renderer/qr_renderer.dart';
import 'package:flutter_label_printer_kit/src/renderer/text_renderer.dart';
import 'package:qr/qr.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double labelDotsPerMm = 8;

class EditorItem {
  EditorItem({required this.id, required this.kind, this.content = '',
    this.x = 16, this.y = 16, this.width = 120, this.fontSize = 24,
    this.bold = false, this.threshold = 160, this.gray,
    this.sourceWidth = 0, this.sourceHeight = 0});

  final int id;
  final String kind;
  String content;
  double x, y, width, fontSize;
  bool bold;
  int threshold, sourceWidth, sourceHeight;
  Uint8List? gray;

  double get height {
    if (kind == 'qr') return width;
    if (kind == 'image') return width * sourceHeight / sourceWidth;
    return const TextRenderer().measure(textElement).height;
  }
  LabelText get textElement => LabelText(content, x: x, y: y,
    fontSize: fontSize, bold: bold, maxWidth: width);
  Rect get bounds => Rect.fromLTWH(x, y, width, height);

  void fit(double paperWidth, double paperHeight) {
    final double maxWidth = kind == 'qr' ? math.min(paperWidth, paperHeight)
      : kind == 'image' ? math.min(paperWidth, paperHeight * sourceWidth / sourceHeight)
      : paperWidth;
    width = width.clamp(math.min(8, maxWidth), maxWidth).toDouble();
    x = x.clamp(0, math.max(0, paperWidth - width)).toDouble().roundToDouble();
    y = y.clamp(0, math.max(0, paperHeight - height)).toDouble().roundToDouble();
  }

  LabelElement toElement() {
    if (kind == 'text') return textElement;
    if (kind == 'qr') return LabelQr(content, x: x, y: y, size: width);
    final int w = math.max(1, width.round());
    final int h = math.max(1, height.round());
    return LabelImage(imageBitmap(w, h), x: x, y: y, widthPx: w, heightPx: h);
  }

  Uint8List imageBitmap(int w, int h) {
    final int stride = (w + 7) ~/ 8;
    final Uint8List mono = Uint8List(stride * h)..fillRange(0, stride * h, 255);
    for (int row = 0; row < h; row++) {
      final int sy = math.min(sourceHeight - 1, row * sourceHeight ~/ h);
      for (int col = 0; col < w; col++) {
        final int sx = math.min(sourceWidth - 1, col * sourceWidth ~/ w);
        if (gray![sy * sourceWidth + sx] < threshold) {
          mono[row * stride + col ~/ 8] &= ~(1 << (7 - col % 8));
        }
      }
    }
    return mono;
  }

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'content': content,
    'x': x, 'y': y, 'width': width, 'fontSize': fontSize, 'bold': bold,
    'threshold': threshold, 'sourceWidth': sourceWidth, 'sourceHeight': sourceHeight,
    if (gray != null) 'gray': base64Encode(gray!)};

  factory EditorItem.fromJson(Map<String, dynamic> j) {
    final String kind = j['kind'] as String;
    if (!['qr', 'text', 'image'].contains(kind)) throw const FormatException('Unknown item');
    final item = EditorItem(id: (j['id'] as num).toInt(), kind: kind,
      content: j['content'] as String? ?? '', x: (j['x'] as num).toDouble(),
      y: (j['y'] as num).toDouble(), width: (j['width'] as num).toDouble(),
      fontSize: (j['fontSize'] as num).toDouble(), bold: j['bold'] == true,
      threshold: (j['threshold'] as num).toInt().clamp(0, 255),
      sourceWidth: (j['sourceWidth'] as num).toInt(),
      sourceHeight: (j['sourceHeight'] as num).toInt(),
      gray: j['gray'] == null ? null : base64Decode(j['gray'] as String));
    if (![item.x, item.y, item.width, item.fontSize].every((v) => v.isFinite) ||
        item.width < 8 || item.fontSize < 8 || item.fontSize > 96) {
      throw const FormatException('Invalid geometry');
    }
    if (kind == 'image' && (item.sourceWidth < 1 || item.sourceHeight < 1 ||
      item.sourceWidth > 512 || item.sourceHeight > 512 ||
      item.gray?.length != item.sourceWidth * item.sourceHeight)) {
      throw const FormatException('Invalid image');
    }
    return item;
  }
}

class LabelEditorPage extends StatefulWidget {
  const LabelEditorPage({super.key, required this.printer, this.pickImage});
  final CtLabelPrinter printer;
  // Injectable file picker keeps image import independently testable.
  final Future<Uint8List?> Function()? pickImage;
  @override
  State<LabelEditorPage> createState() => LabelEditorPageState();
}

class LabelEditorPageState extends State<LabelEditorPage> {
  static const draftKey = 'claybel.labelEditor.v1';
  final List<EditorItem> items = [];
  double widthMm = 50, heightMm = 30;
  int? selectedId;
  int _nextId = 1;
  bool _loading = true, _busy = false;
  Timer? _saveTimer;
  String? _notice;
  Future<void> _saveQueue = Future<void>.value();

  double get paperWidth => (widthMm * labelDotsPerMm).roundToDouble();
  double get paperHeight => (heightMm * labelDotsPerMm).roundToDouble();
  EditorItem? get selected {
    for (final item in items) {
      if (item.id == selectedId) return item;
    }
    return null;
  }
  LabelDocument get document => LabelDocument(widthMm: widthMm, heightMm: heightMm,
    children: items.where((item) => item.kind == 'image' || item.content.isNotEmpty)
      .map((item) => item.toElement()).toList());

  @override
  void initState() {
    super.initState();
    widthMm = widget.printer.settings.defaultPaperWidthMm.clamp(10, 80).toDouble();
    heightMm = widget.printer.settings.defaultPaperHeightMm.clamp(10, 150).toDouble();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(draftKey);
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        widthMm = (j['widthMm'] as num).toDouble().clamp(10, 80);
        heightMm = (j['heightMm'] as num).toDouble().clamp(10, 150);
        if (!widthMm.isFinite || !heightMm.isFinite) throw const FormatException('Invalid size');
        final saved = j['items'] as List;
        if (saved.length > 20) throw const FormatException('Too many items');
        items.addAll(saved.map((v) => EditorItem.fromJson(Map<String, dynamic>.from(v as Map))));
      } else {
        items.add(EditorItem(id: 1, kind: 'text', content: 'My label', width: paperWidth * .5, bold: true));
        items.add(EditorItem(id: 2, kind: 'qr', content: 'https://example.com',
          x: paperWidth * .55, y: paperHeight * .15,
          width: math.min(paperWidth * .4, paperHeight * .7)));
      }
    } catch (_) {
      items.clear();
      _notice = 'Saved layout could not be opened. Start a new label below.';
    }
    for (final item in items) { item.fit(paperWidth, paperHeight); }
    _nextId = items.fold<int>(0, (v, item) => math.max(v, item.id)) + 1;
    selectedId = items.isEmpty ? null : items.last.id;
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic> get draft => {'widthMm': widthMm, 'heightMm': heightMm,
    'items': items.map((item) => item.toJson()).toList()};

  Future<void> saveDraft() {
    _saveTimer?.cancel();
    final raw = jsonEncode(draft);
    _saveQueue = _saveQueue.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(draftKey, raw)) throw StateError('Unable to save layout');
    });
    return _saveQueue;
  }

  void changed(VoidCallback mutation) {
    setState(() {
      mutation();
      for (final item in items) { item.fit(paperWidth, paperHeight); }
    });
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      saveDraft().catchError((Object _) {
        if (mounted) setState(() => _notice = 'Could not save layout. Please try Save again.');
      });
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (!_loading) { unawaited(saveDraft().catchError((Object _) {})); }
    super.dispose();
  }

  String? get validationError {
    if (items.isEmpty || document.children.isEmpty) return 'Add text, a QR code, or an image to print.';
    for (final item in items) {
      if (item.kind == 'text' && item.content.isEmpty) continue;
      if (item.bounds.bottom > paperHeight + .5) return 'An item is too tall. Reduce its size or shorten the text.';
      if (item.kind == 'qr') {
        if (item.content.isEmpty) return 'Enter data for the QR code or remove it.';
        try {
          final code = QrImage(QrCode.fromData(data: item.content, errorCorrectLevel: QrErrorCorrectLevel.M));
          if (item.width < (code.moduleCount + 8) * 2) return 'Enlarge the QR code for reliable printing.';
        } catch (_) { return 'QR data is too long. Shorten it.'; }
      }
    }
    return null;
  }

  void add(String kind) {
    if (items.length >= 20) { _message('A label can contain up to 20 items.'); return; }
    changed(() {
      final item = EditorItem(id: _nextId++, kind: kind,
        content: kind == 'qr' ? 'https://example.com' : 'Text',
        width: kind == 'qr' ? math.min(paperWidth, paperHeight) * .65 : paperWidth * .6);
      items.add(item);
      selectedId = item.id;
    });
  }

  Future<void> importImage() async {
    if (items.length >= 20) { _message('A label can contain up to 20 items.'); return; }
    setState(() => _busy = true);
    try {
      Uint8List? bytes;
      if (widget.pickImage != null) {
        bytes = await widget.pickImage!();
      } else {
        final file = await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'], mimeTypes: ['image/*'])]);
        if (file == null) return;
        if (await file.length() > 20 * 1024 * 1024) throw StateError('Choose an image smaller than 20 MB.');
        bytes = await file.readAsBytes();
      }
      if (bytes == null || !mounted) return;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final scale = math.min(1.0, 512 / math.max(descriptor.width, descriptor.height));
      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()));
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (rgba == null) throw StateError('Could not decode this image.');
      final gray = rgbaToGray(rgba.buffer.asUint8List(), image.width, image.height);
      final item = EditorItem(id: _nextId++, kind: 'image', gray: gray,
        sourceWidth: image.width, sourceHeight: image.height, width: paperWidth * .6);
      image.dispose(); codec.dispose(); descriptor.dispose(); buffer.dispose();
      if (mounted) changed(() { items.add(item); selectedId = item.id; });
    } catch (e) {
      if (mounted) _message('Image import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> printLayout() async {
    final error = validationError;
    if (error != null) { _message(error); return; }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await saveDraft();
      await widget.printer.printLabel(document, description: 'Custom label');
      if (mounted) _message('Label sent to printer');
    } catch (e) {
      if (mounted) _message('Print failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectAt(Offset point) {
    int? id;
    for (final item in items.reversed) {
      if (item.bounds.inflate(4).contains(point)) { id = item.id; break; }
    }
    setState(() => selectedId = id);
  }

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> change, {Key? key}) {
    max = math.max(min + .125, max);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$label: ${value.toStringAsFixed(1)} mm'),
      Slider(key: key, value: value.clamp(min, max), min: min, max: max,
        onChanged: _busy ? null : (v) => changed(() => change(v))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final item = selected;
    final error = _loading ? null : validationError;
    return Scaffold(
      appBar: AppBar(title: const Text('Label editor'), actions: [
        IconButton(tooltip: 'Save layout', icon: const Icon(Icons.save_outlined),
          onPressed: _loading || _busy ? null : () async {
            try { await saveDraft(); if (mounted) _message('Layout saved'); }
            catch (_) { if (mounted) _message('Could not save layout'); }
          }),
      ]),
      body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.all(16), children: [
          if (_notice != null) Text(_notice!),
          Row(children: [
            Expanded(child: TextFormField(key: const Key('paper-width'), initialValue: '$widthMm',
              decoration: const InputDecoration(labelText: 'Label width (mm)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              enabled: !_busy, onChanged: (s) { final v = double.tryParse(s);
                if (v != null && v >= 10 && v <= 80) changed(() => widthMm = v); })),
            const SizedBox(width: 12),
            Expanded(child: TextFormField(key: const Key('paper-height'), initialValue: '$heightMm',
              decoration: const InputDecoration(labelText: 'Label height (mm)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              enabled: !_busy, onChanged: (s) { final v = double.tryParse(s);
                if (v != null && v >= 10 && v <= 150) changed(() => heightMm = v); })),
          ]),
          const SizedBox(height: 12),
          const Text('Tap an item to select it. Drag it to move. Use the corner handle or size slider to resize.'),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, constraints) {
            final scale = math.min(constraints.maxWidth / paperWidth, 420 / paperHeight);
            return Center(child: SizedBox(width: paperWidth * scale, height: paperHeight * scale,
              child: Stack(children: [
                Positioned.fill(child: GestureDetector(key: const Key('label-canvas'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: _busy ? null : (d) => _selectAt(d.localPosition / scale),
                  onPanStart: _busy ? null : (d) => _selectAt(d.localPosition / scale),
                  onPanUpdate: _busy ? null : (d) {
                    final target = selected;
                    if (target != null) changed(() { target.x += d.delta.dx / scale; target.y += d.delta.dy / scale; });
                  },
                  child: ClipRect(child: CustomPaint(painter: EditorPainter(document, items, selectedId))))),
                if (item != null) Positioned(
                  left: ((item.bounds.right * scale) - 16).clamp(0, math.max(0, paperWidth * scale - 32)),
                  top: ((item.bounds.bottom * scale) - 16).clamp(0, math.max(0, paperHeight * scale - 32)),
                  width: 32, height: 32,
                  child: GestureDetector(key: const Key('resize-handle'), behavior: HitTestBehavior.opaque,
                    onPanUpdate: _busy ? null : (d) => changed(() {
                      item.width += d.delta.dx / scale;
                      if (item.kind == 'text') item.fontSize = (item.fontSize + d.delta.dy / scale * .2).clamp(8, 96);
                    }),
                    child: DecoratedBox(decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.open_in_full, color: Colors.white, size: 20)))),
              ])));
          }),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: _busy ? null : () => add('text'), icon: const Icon(Icons.text_fields), label: const Text('Add text')),
            OutlinedButton.icon(onPressed: _busy ? null : () => add('qr'), icon: const Icon(Icons.qr_code), label: const Text('Add QR')),
            OutlinedButton.icon(onPressed: _busy ? null : importImage, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Import image / QR')),
          ]),
          if (items.isNotEmpty) Wrap(spacing: 8, children: items.map((v) => ChoiceChip(
            label: Text('${v.kind == 'qr' ? 'QR' : v.kind == 'image' ? 'Image' : 'Text'} ${items.indexOf(v) + 1}'),
            selected: v.id == selectedId, onSelected: _busy ? null : (_) => setState(() => selectedId = v.id))).toList()),
          if (item != null) ...[
            const Divider(height: 24),
            if (item.kind != 'image') TextFormField(key: ValueKey('content-${item.id}'), initialValue: item.content,
              maxLines: item.kind == 'text' ? 3 : 2, enabled: !_busy,
              decoration: InputDecoration(labelText: item.kind == 'qr' ? 'QR data' : 'Text'),
              onChanged: (s) => changed(() => item.content = s)),
            const SizedBox(height: 8),
            _slider(item.kind == 'qr' ? 'QR size' : item.kind == 'image' ? 'Image width' : 'Text box width',
              item.width / 8, 1, (item.kind == 'qr' ? math.min(paperWidth, paperHeight)
              : item.kind == 'image' ? math.min(paperWidth, paperHeight * item.sourceWidth / item.sourceHeight) : paperWidth) / 8,
              (v) => item.width = v * 8, key: const Key('item-size')),
            if (item.kind == 'text') ...[
              _slider('Text size', item.fontSize / 8, 1, 12, (v) => item.fontSize = v * 8),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Bold'), value: item.bold,
                onChanged: _busy ? null : (v) => changed(() => item.bold = v)),
            ],
            if (item.kind == 'image') ...[
              const Text('Black and white contrast'),
              Slider(value: item.threshold.toDouble(), min: 20, max: 235,
                onChanged: _busy ? null : (v) => changed(() => item.threshold = v.round())),
              const Text('Import a cropped QR image with its white border. Images keep their proportions.'),
            ],
            _slider('Horizontal position', item.x / 8, 0, math.max(0, paperWidth - item.width) / 8,
              (v) => item.x = v * 8, key: const Key('item-x')),
            _slider('Vertical position', item.y / 8, 0, math.max(0, paperHeight - item.height) / 8,
              (v) => item.y = v * 8, key: const Key('item-y')),
            Row(children: [
              TextButton.icon(onPressed: _busy ? null : () => changed(() {
                item.x = (paperWidth - item.width) / 2; item.y = (paperHeight - item.height) / 2;
              }), icon: const Icon(Icons.center_focus_strong), label: const Text('Center')),
              TextButton.icon(onPressed: _busy ? null : () => changed(() {
                items.remove(item); selectedId = items.isEmpty ? null : items.last.id;
              }), icon: const Icon(Icons.delete_outline), label: const Text('Remove item')),
            ]),
          ],
          const SizedBox(height: 12),
          if (error != null) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          FilledButton.icon(onPressed: _busy || error != null ? null : printLayout,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.print),
            label: const Text('Print this label')),
          const SizedBox(height: 12),
          TextButton.icon(onPressed: _busy || error != null ? null : () {
            final label = document;
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Print preview')),
              body: ListView(padding: const EdgeInsets.all(16), children: [LabelPreview(label: label)]))));
          }, icon: const Icon(Icons.preview_outlined), label: const Text('Print preview')),
          const Text('Match label dimensions to the roll loaded in the printer. Your layout is saved on this device.'),
        ]),
    );
  }
}

Uint8List rgbaToGray(Uint8List rgba, int width, int height) {
  final gray = Uint8List(width * height);
  for (int p = 0; p < gray.length; p++) {
    final i = p * 4;
    final luminance = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) ~/ 1000;
    final alpha = rgba[i + 3];
    gray[p] = (luminance * alpha + 255 * (255 - alpha)) ~/ 255;
  }
  return gray;
}

class EditorPainter extends CustomPainter {
  const EditorPainter(this.document, this.items, this.selectedId);
  final LabelDocument document;
  final List<EditorItem> items;
  final int? selectedId;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final scale = size.width / (document.widthMm * 8);
    canvas.save();
    canvas.scale(scale);
    for (final element in document.children) {
      if (element is LabelText) const TextRenderer().paint(canvas, element);
      if (element is LabelQr) {
        try { const QrRenderer().paint(canvas, element); } catch (_) {}
      }
      if (element is LabelImage) {
        final stride = (element.widthPx + 7) ~/ 8;
        final paint = Paint()..color = Colors.black..isAntiAlias = false;
        for (int row = 0; row < element.heightPx; row++) {
          int? run;
          for (int col = 0; col <= element.widthPx; col++) {
            final black = col < element.widthPx &&
              (element.monoBitmap[row * stride + col ~/ 8] & (1 << (7 - col % 8))) == 0;
            if (black) { run ??= col; }
            else if (run != null) {
              canvas.drawRect(Rect.fromLTWH(element.x + run, element.y + row, (col - run).toDouble(), 1), paint);
              run = null;
            }
          }
        }
      }
    }
    for (final item in items) {
      if (item.id == selectedId) canvas.drawRect(item.bounds,
        Paint()..color = Colors.blue..style = PaintingStyle.stroke..strokeWidth = 2 / scale);
    }
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant EditorPainter oldDelegate) => true;
}
