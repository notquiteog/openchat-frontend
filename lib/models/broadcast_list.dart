/// A local-only broadcast list: a saved set of contacts you can message at once.
/// Each send fans out to a separate sealed-sender DM, so recipients never learn
/// they're on a list. Stored only on-device (encrypted local state).
class BroadcastList {
  final String id;
  final String name;
  final List<String> memberUserIds;

  const BroadcastList({
    required this.id,
    required this.name,
    required this.memberUserIds,
  });

  factory BroadcastList.fromJson(Map<String, dynamic> json) => BroadcastList(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    memberUserIds: ((json['member_user_ids'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'member_user_ids': memberUserIds,
  };

  BroadcastList copyWith({String? name, List<String>? memberUserIds}) =>
      BroadcastList(
        id: id,
        name: name ?? this.name,
        memberUserIds: memberUserIds ?? this.memberUserIds,
      );
}
