class OperatorMetrics {
  final PushOperatorMetrics push;
  final DatabaseOperatorMetrics db;
  final HubOperatorMetrics hub;

  const OperatorMetrics({
    required this.push,
    required this.db,
    required this.hub,
  });

  factory OperatorMetrics.fromJson(Map<String, dynamic> json) {
    return OperatorMetrics(
      push: PushOperatorMetrics.fromJson(_asMap(json['push'])),
      db: DatabaseOperatorMetrics.fromJson(_asMap(json['db'])),
      hub: HubOperatorMetrics.fromJson(_asMap(json['hub'])),
    );
  }
}

class PushOperatorMetrics {
  final bool enabled;
  final int sent;
  final int failed;
  final int dropped;
  final int droppedSends;
  final int queueDepth;
  final int queueCapacity;

  const PushOperatorMetrics({
    required this.enabled,
    required this.sent,
    required this.failed,
    required this.dropped,
    required this.droppedSends,
    required this.queueDepth,
    required this.queueCapacity,
  });

  factory PushOperatorMetrics.fromJson(Map<String, dynamic> json) {
    final legacyDropped = _readInt(json['dropped_sends']);
    final dropped = _readInt(json['dropped']);
    return PushOperatorMetrics(
      enabled: json['enabled'] == true,
      sent: _readInt(json['sent']),
      failed: _readInt(json['failed']),
      dropped: dropped == 0 ? legacyDropped : dropped,
      droppedSends: legacyDropped,
      queueDepth: _readInt(json['queue_depth']),
      queueCapacity: _readInt(json['queue_capacity']),
    );
  }

  double? get queueFill {
    if (queueCapacity <= 0) return null;
    return (queueDepth / queueCapacity).clamp(0.0, 1.0);
  }
}

class DatabaseOperatorMetrics {
  final int acquiredConnections;
  final int totalConnections;
  final int idleConnections;
  final int maxConnections;
  final int acquireCount;
  final int emptyAcquireCount;

  const DatabaseOperatorMetrics({
    required this.acquiredConnections,
    required this.totalConnections,
    required this.idleConnections,
    required this.maxConnections,
    required this.acquireCount,
    required this.emptyAcquireCount,
  });

  factory DatabaseOperatorMetrics.fromJson(Map<String, dynamic> json) {
    return DatabaseOperatorMetrics(
      acquiredConnections: _readInt(json['acquired_conns']),
      totalConnections: _readInt(json['total_conns']),
      idleConnections: _readInt(json['idle_conns']),
      maxConnections: _readInt(json['max_conns']),
      acquireCount: _readInt(json['acquire_count']),
      emptyAcquireCount: _readInt(json['empty_acquire_count']),
    );
  }
}

class HubOperatorMetrics {
  final int users;
  final int connections;

  const HubOperatorMetrics({required this.users, required this.connections});

  factory HubOperatorMetrics.fromJson(Map<String, dynamic> json) {
    return HubOperatorMetrics(
      users: _readInt(json['users']),
      connections: _readInt(json['connections']),
    );
  }
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
