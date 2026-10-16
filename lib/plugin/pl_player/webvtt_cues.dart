class WebVttCue {
  const WebVttCue(this.startMs, this.endMs, this.text);
  final int startMs;
  final int endMs;
  final String text;
}

/// External subtitles follow the native playhead without reopening video/audio.
List<WebVttCue> parseWebVtt(String source) {
  int milliseconds(String value) {
    final fields = value.replaceAll(',', '.').split(':');
    final seconds = double.parse(fields.removeLast());
    final minutes = int.parse(fields.removeLast());
    final hours = fields.isEmpty ? 0 : int.parse(fields.removeLast());
    return ((hours * 3600 + minutes * 60 + seconds) * 1000).round();
  }

  final timestamp = RegExp(
    r'((?:\d+:)?\d{2}:\d{2}[.,]\d{3})\s+-->\s+((?:\d+:)?\d{2}:\d{2}[.,]\d{3})',
  );
  final cues = <WebVttCue>[];
  for (final block
      in source.replaceAll('\r\n', '\n').split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final index = lines.indexWhere(timestamp.hasMatch);
    if (index < 0) continue;
    final match = timestamp.firstMatch(lines[index])!;
    final text = lines
        .skip(index + 1)
        .join('\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .trim();
    cues.add(WebVttCue(milliseconds(match[1]!), milliseconds(match[2]!), text));
  }
  cues.sort((a, b) => a.startMs.compareTo(b.startMs));
  return cues;
}
