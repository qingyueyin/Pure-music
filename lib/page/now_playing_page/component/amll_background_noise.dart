import 'dart:typed_data';
import 'dart:ui' as ui;

Future<ui.Image> buildAmllNoiseTile({int size = 64, int seed = 0}) async {
	final resolvedSize = size.clamp(4, 256);
	final pixels = Uint8List(resolvedSize * resolvedSize * 4);
	var state = (seed ^ 0x6D2B79F5) & 0xFFFFFFFF;

	for (var i = 0; i < pixels.length; i += 4) {
		state = (state * 1664525 + 1013904223) & 0xFFFFFFFF;
		final value = 104 + ((state >> 24) & 0x5F);
		pixels[i] = value;
		pixels[i + 1] = value;
		pixels[i + 2] = value;
		pixels[i + 3] = 0xFF;
	}

	return _rawRgbaToImage(pixels, resolvedSize, resolvedSize);
}

Future<ui.Image> _rawRgbaToImage(
	Uint8List rgba,
	int width,
	int height,
) async {
	final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
	try {
		final descriptor = ui.ImageDescriptor.raw(
			buffer,
			width: width,
			height: height,
			pixelFormat: ui.PixelFormat.rgba8888,
			rowBytes: width * 4,
		);
		try {
			final codec = await descriptor.instantiateCodec();
			try {
				final frame = await codec.getNextFrame();
				return frame.image;
			} finally {
				codec.dispose();
			}
		} finally {
			descriptor.dispose();
		}
	} finally {
		buffer.dispose();
	}
}
