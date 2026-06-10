import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/widgets/chat_search_results_view.dart';

// Leaf-level coverage for the shared search results view (the full screen
// can't be pumped — ChatProvider opens sockets). Queries shorter than two
// characters never touch providers, so the idle/hint state is testable.
void main() {
  Future<void> pump(WidgetTester tester, String query) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatSearchResultsView(query: query, onSelect: (_) {}),
        ),
      ),
    );
  }

  testWidgets('empty query shows the search hint', (tester) async {
    await pump(tester, '');
    expect(
      find.text('Search users, channels, and local messages'),
      findsOneWidget,
    );
  });

  testWidgets('single-character query still shows the hint', (tester) async {
    await pump(tester, 'a');
    expect(
      find.text('Search users, channels, and local messages'),
      findsOneWidget,
    );
  });

  test('selection types carry their payloads', () {
    const user = UserSearchSelection('user-1');
    expect(user.userID, 'user-1');
    // The sealed hierarchy is what the home shell switches on.
    expect(user, isA<ChatSearchSelection>());
  });
}
