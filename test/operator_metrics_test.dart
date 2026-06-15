import 'package:flutter_test/flutter_test.dart';
import 'package:openchat/models/operator_metrics.dart';

void main() {
  test('operator metrics parse push db and hub counters', () {
    final metrics = OperatorMetrics.fromJson({
      'push': {
        'enabled': true,
        'sent': 12,
        'failed': 3,
        'dropped': 2,
        'dropped_sends': 2,
        'queue_depth': 4,
        'queue_capacity': 8,
      },
      'db': {
        'acquired_conns': 1,
        'total_conns': 5,
        'idle_conns': 4,
        'max_conns': 10,
        'acquire_count': 99,
        'empty_acquire_count': 7,
      },
      'hub': {'users': 6, 'connections': 9},
    });

    expect(metrics.push.enabled, isTrue);
    expect(metrics.push.sent, 12);
    expect(metrics.push.failed, 3);
    expect(metrics.push.dropped, 2);
    expect(metrics.push.queueFill, 0.5);
    expect(metrics.db.maxConnections, 10);
    expect(metrics.db.emptyAcquireCount, 7);
    expect(metrics.hub.connections, 9);
  });

  test('operator metrics accept legacy dropped_sends only', () {
    final metrics = OperatorMetrics.fromJson({
      'push': {'enabled': false, 'dropped_sends': '5'},
    });

    expect(metrics.push.enabled, isFalse);
    expect(metrics.push.dropped, 5);
    expect(metrics.push.queueFill, isNull);
    expect(metrics.db.totalConnections, 0);
    expect(metrics.hub.users, 0);
  });
}
