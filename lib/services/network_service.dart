import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Coarse network class used for auto-download gating.
///
/// Note: cellular *roaming* cannot be detected reliably across platforms, so it
/// is folded into [mobile]. Treat "roaming" policy as best-effort only.
enum NetworkClass { wifi, mobile, none }

/// Tracks the current connection type so auto-download policies can gate media.
class NetworkService extends ChangeNotifier {
  NetworkClass _current = NetworkClass.wifi;
  NetworkClass get current => _current;

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  Future<void> init() async {
    try {
      _apply(await _connectivity.checkConnectivity());
    } catch (_) {
      // Platform without connectivity support — assume wifi (unrestricted).
      _current = NetworkClass.wifi;
    }
    _sub = _connectivity.onConnectivityChanged.listen(_apply);
  }

  void _apply(List<ConnectivityResult> results) {
    final next = _classify(results);
    if (next != _current) {
      _current = next;
      notifyListeners();
    }
  }

  NetworkClass _classify(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return NetworkClass.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkClass.mobile;
    }
    if (results.contains(ConnectivityResult.none) || results.isEmpty) {
      return NetworkClass.none;
    }
    // vpn / bluetooth / other → treat as unmetered.
    return NetworkClass.wifi;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
