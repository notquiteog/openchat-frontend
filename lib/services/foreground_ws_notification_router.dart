import 'background_ws_service.dart';
import 'websocket_service.dart';

class ForegroundWsNotificationRouter {
  const ForegroundWsNotificationRouter._();

  static NotificationIntent? intentForEvent(
    WsEvent event, {
    required bool showSensitive,
    required bool isDesktop,
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
    );
  }
}
