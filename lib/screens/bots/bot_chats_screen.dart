import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../config/api_config.dart';
import '../../models/conversation.dart';
import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../services/api_service.dart';
import '../../widgets/glass.dart';
import '../chat/chat_screen.dart';

/// Bots tab: lists the user's existing bot conversations and lets them search
/// for bots to start a new chat. Only shown when "Bots" is enabled as its own
/// tab in settings; otherwise bot chats appear inline in the Chats list.
class BotChatsScreen extends StatefulWidget {
  const BotChatsScreen({super.key});

  @override
  State<BotChatsScreen> createState() => _BotChatsScreenState();
}

class _BotChatsScreenState extends State<BotChatsScreen> {
  final _searchCtrl = TextEditingController();
  List<User> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final found = await context.read<ApiService>().searchUsers(query.trim());
      setState(() => _results = found.where((u) => u.isBot).toList());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openBot(String userID) async {
    final conv = await context.read<ChatProvider>().openDM(userID);
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final chat = context.watch<ChatProvider>();
    final currentUserID = auth.currentUser?.id ?? '';
    final botChats = chat.conversations
        .where((c) => c.isBotDM(currentUserID))
        .toList();
    return GlassScreenScaffold(
      title: const Text('Bots'),
      body: Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + kToolbarHeight),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: GlassSearchBar(
              controller: _searchCtrl,
              placeholder: 'Search bots by @username…',
              onChanged: _search,
            ),
          ),
          if (_searching) const GlassProgressIndicator.linear(),
          Expanded(
            child: _searchCtrl.text.isNotEmpty
                ? _buildSearchResults()
                : _buildBotChats(botChats, currentUserID),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_results.isEmpty) {
      return const Center(
        child: Text('No bots found', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 8,
      ),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final bot = _results[i];
        return GlassListTile(
          leading: CircleAvatar(
            backgroundImage: bot.avatarUrl != null
                ? CachedNetworkImageProvider(
                    ApiConfig.resolveMedia(bot.avatarUrl!),
                  )
                : null,
            child: bot.avatarUrl == null
                ? Text(bot.username[0].toUpperCase())
                : null,
          ),
          title: Text('@${bot.username}'),
          subtitle: bot.bio != null ? Text(bot.bio!) : const Text('Bot'),
          trailing: const Icon(Icons.smart_toy_outlined),
          onTap: () => _openBot(bot.id),
        );
      },
    );
  }

  Widget _buildBotChats(List<Conversation> chats, String currentUserID) {
    if (chats.isEmpty) {
      return const Center(
        child: Text(
          'Search for a bot above to start chatting',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: MediaQuery.paddingOf(context).bottom + 8,
      ),
      itemCount: chats.length,
      itemBuilder: (context, i) {
        final conv = chats[i];
        final name = conv.displayName(currentUserID);
        final avatar = conv.displayAvatar(currentUserID);
        return GlassListTile(
          leading: CircleAvatar(
            backgroundImage: avatar != null
                ? CachedNetworkImageProvider(ApiConfig.resolveMedia(avatar))
                : null,
            child: avatar == null
                ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?')
                : null,
          ),
          title: Text('@$name'),
          subtitle: conv.lastMessage != null && conv.lastMessage!.isDecrypted
              ? Text(
                  conv.lastMessage!.decryptedContent!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => ChatScreen(conversation: conv)),
          ),
        );
      },
    );
  }
}
