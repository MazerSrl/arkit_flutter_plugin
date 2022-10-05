import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/services.dart';

// Type definitions to enforce a consistent use of the API
typedef AnchorUploadedHandler = void Function(ARKitAnchor arAnchor);
typedef AnchorDownloadedHandler = ARKitAnchor Function(
    Map<String, dynamic> serializedAnchor);

/// Handles all anchor-related functionality of an [ARView], including configuration and usage of collaborative sessions
class ARAnchorManager {
  /// Platform channel used for communication from and to [ARAnchorManager]
  late MethodChannel _channel;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Reference to all anchors that are being uploaded to the google cloud anchor API
  List<ARKitAnchor> pendingAnchors = [];

  /// Callback that is triggered once an anchor has successfully been uploaded to the google cloud anchor API
  AnchorUploadedHandler? onAnchorUploaded;

  /// Callback that is triggered once an anchor has successfully been downloaded from the google cloud anchor API and resolved within the current scene
  AnchorDownloadedHandler? onAnchorDownloaded;

  ARAnchorManager(int id, {this.debug = false}) {
    _channel = MethodChannel('aranchors_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    if (debug) {
      print('ARAnchorManager initialized');
    }
  }

  /// Activates collaborative AR mode (using Google Cloud Anchors)
  initGoogleCloudAnchorMode() async {
    _channel.invokeMethod<bool>('initGoogleCloudAnchorMode', {});
  }

  Future<dynamic> _platformCallHandler(MethodCall call) async {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          print(call.arguments);
          break;
        case 'onCloudAnchorUploaded':
          final nodeName = call.arguments['nodeName'];
          final cloudanchorid = call.arguments['cloudanchorid'];
          print(
              'UPLOADED ANCHOR WITH ID: ' + cloudanchorid + ', NAME: ' + nodeName);
          final currentAnchor =
              pendingAnchors.where((element) => element.nodeName == nodeName).first;
          // Update anchor with cloud anchor ID
          (currentAnchor as ARKitPlaneAnchor).cloudanchorid = cloudanchorid;
          // Remove anchor from list of pending anchors
          pendingAnchors.remove(currentAnchor);
          // Notify callback
          if (onAnchorUploaded != null) {
            onAnchorUploaded!(currentAnchor);
          }
          break;
        case 'onAnchorDownloadSuccess':
          final serializedAnchor = call.arguments;
          if (onAnchorDownloaded != null) {
            ARKitAnchor anchor = onAnchorDownloaded!(
                Map<String, dynamic>.from(serializedAnchor));
            return anchor.nodeName;
          } else {
            return serializedAnchor['nodeName'];
          }
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: ' + e.toString());
    }
    return Future.value();
  }

  /// Add given anchor to the underlying AR scene
  Future<bool?> addAnchor(ARKitAnchor anchor) async {
    try {
      return await _channel.invokeMethod<bool>('addAnchor', anchor.toJson());
    } on PlatformException {
      return false;
    }
  }

  /// Remove given anchor and all its children from the AR Scene
  removeAnchor(ARKitAnchor anchor) {
    _channel.invokeMethod<String>('removeAnchor', {'nodeName': anchor.nodeName});
  }

  /// Upload given anchor from the underlying AR scene to the Google Cloud Anchor API
  Future<bool?> uploadAnchor(ARKitAnchor anchor) async {
    try {
      final response =
          await _channel.invokeMethod<bool>('uploadAnchor', anchor.toJson());
      pendingAnchors.add(anchor);
      return response;
    } on PlatformException {
      return false;
    }
  }

  /// Try to download anchor with the given ID from the Google Cloud Anchor API and add it to the scene
  Future<bool?> downloadAnchor(String cloudanchorid) async {
    print('TRYING TO DOWNLOAD ANCHOR WITH ID ' + cloudanchorid);
    return _channel
        .invokeMethod<bool>('downloadAnchor', {'cloudanchorid': cloudanchorid});
  }
}
