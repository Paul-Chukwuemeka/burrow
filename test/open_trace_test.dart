import 'package:burrow/utils/open_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    OpenTrace.enabled = false;
    OpenTrace.reset();
  });

  test('span is a no-op when disabled', () {
    OpenTrace.span('parse', const Duration(milliseconds: 10));
    expect(OpenTrace.spansMicros, isEmpty);
  });

  test('span accumulates per name when enabled', () {
    OpenTrace.enabled = true;
    OpenTrace.span('parse', const Duration(milliseconds: 10));
    OpenTrace.span('parse', const Duration(milliseconds: 5));
    OpenTrace.span('fonts', const Duration(milliseconds: 2));
    expect(OpenTrace.spansMicros['parse'], 15000);
    expect(OpenTrace.spansMicros['fonts'], 2000);
  });

  test('reset clears accumulated spans', () {
    OpenTrace.enabled = true;
    OpenTrace.span('parse', const Duration(milliseconds: 1));
    OpenTrace.reset();
    expect(OpenTrace.spansMicros, isEmpty);
  });
}
