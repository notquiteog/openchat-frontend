/// A bot's public slash-command (mirrors the server `TGBotCommand`). Surfaced in
/// the bot-DM composer's `/command` autocomplete (#31).
class BotCommand {
  final String command;
  final String description;

  const BotCommand({required this.command, required this.description});

  factory BotCommand.fromJson(Map<String, dynamic> json) => BotCommand(
    command: (json['command'] as String? ?? '').trim(),
    description: (json['description'] as String? ?? '').trim(),
  );

  Map<String, dynamic> toJson() => {
    'command': command,
    'description': description,
  };
}
