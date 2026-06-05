import 'background_ws_service.dart';
import 'websocket_service.dart';
import '../utils/local_conversation_preferences.dart';

class ForegroundWsNotificationRouter {
  const ForegroundWsNotificationRouter._();

  static NotificationIntent? intentForEvent(
    WsEvent event, {
    required bool showSensitive,
    required bool isDesktop,
    Set<String> mutedConversationIds = const {},
    Map<String, ConversationNotificationPreference>
        conversationNotificationPreferences =
        const {},
  }) {
    if (!isDesktop) return null;

    final type = switch (event.type) {
      WsEventType.newMessage => 'new_message',
      WsEventType.callOffer => 'call_offer',
      _ => null,
    };
    if (type == null) return null;

    return BackgroundWsService.notificationIntentFromEvent(
      type: type,
      data: event.data,
      showSensitive: showSensitive,
      mutedConversationIds: mutedConversationIds,
      conversationNotificationPreferences: conversationNotificationPreferences,
    );
  }
}
