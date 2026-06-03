import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/utils/account_security_duration.dart';

void main() {
  test('normalizes inactivity deletion days to backend range', () {
    expect(normalizeInactiveDeletionDays(null), 0);
    expect(normalizeInactiveDeletionDays(-1), 0);
    expect(normalizeInactiveDeletionDays(30), 30);
    expect(
      normalizeInactiveDeletionDays(4000),
      accountInactivityDeletionMaxDays,
    );
  });

  test('formats inactivity deletion labels precisely in days', () {
    expect(inactiveDeletionDurationLabel(0), 'Off');
    expect(inactiveDeletionDurationLabel(1), '1 day');
    expect(inactiveDeletionDurationLabel(30), '30 days');
    expect(inactiveDeletionSummaryLabel(365), 'After 365 days');
  });
}
