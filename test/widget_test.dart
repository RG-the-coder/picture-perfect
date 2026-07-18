import 'package:flutter_test/flutter_test.dart';
import 'package:picture_perfect/picture_perfect_app.dart';

void main() {
  testWidgets('welcome screen presents every starting path', (tester) async {
    await tester.pumpWidget(const PicturePerfectApp());
    await tester.pump();

    expect(find.text('Picture Perfect'), findsOneWidget);
    expect(find.text('Open camera'), findsOneWidget);
    expect(find.text('Upload a photo'), findsOneWidget);
    expect(find.text('Try a sample shot'), findsOneWidget);
    expect(find.text('A better photo in three moves'), findsOneWidget);
  });
}
