import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:arkit_plugin_example/firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geoflutterfire/geoflutterfire.dart';
import 'package:geolocator/geolocator.dart';
import 'package:collection/collection.dart';

class CloudAnchorWidget extends StatefulWidget {
  CloudAnchorWidget({Key? key}) : super(key: key);
  @override
  _CloudAnchorWidgetState createState() => _CloudAnchorWidgetState();
}

class _CloudAnchorWidgetState extends State<CloudAnchorWidget> {
  // Firebase stuff
  bool _initialized = false;
  bool _error = false;
  FirebaseManager firebaseManager = FirebaseManager();
  Map anchorsInDownloadProgress = <String, Map>{};

  late ARAnchorManager arAnchorManager;
  late ARLocationManager arLocationManager;
  late ARKitController arController;

  List<ARKitNode> nodes = [];
  List<ARKitAnchor> anchors = [];
  String lastUploadedAnchor = '';

  bool readyToUpload = false;
  bool readyToDownload = true;

  @override
  void initState() {
    firebaseManager.initializeFlutterFire().then((value) => setState(() {
          _initialized = value;
          _error = !value;
        }));

    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show error message if initialization failed
    if (_error) {
      return Scaffold(
          appBar: AppBar(
            title: const Text('Cloud Anchors'),
          ),
          body: Container(
              child: Center(
                  child: Column(
            children: [
              Text('Firebase initialization failed: ' + _error.toString()),
              ElevatedButton(
                  child: Text('Retry'), onPressed: () => {initState()})
            ],
          ))));
    }

    // Show a loader until FlutterFire is initialized
    if (!_initialized) {
      return Scaffold(
          appBar: AppBar(
            title: const Text('Cloud Anchors'),
          ),
          body: Container(
              child: Center(
                  child: Column(children: [
            CircularProgressIndicator(),
            Text('Initializing Firebase')
          ]))));
    }

    return Scaffold(
        appBar: AppBar(
          title: const Text('Cloud Anchors'),
        ),
        body: Container(
            child: Stack(children: [
              ARKitSceneView(
                onARKitViewCreated: onARKitViewCreated,
                planeDetection: ARPlaneDetection.horizontalAndVertical,
                showFeaturePoints: true,
              ),
          Align(
            alignment: FractionalOffset.bottomCenter,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton(
                      onPressed: onRemoveEverything,
                      child: Text('Remove Everything')),
                ]),
          ),
          Align(
            alignment: FractionalOffset.topCenter,
            child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Visibility(
                      visible: readyToUpload,
                      child: ElevatedButton(
                          onPressed: onUploadButtonPressed,
                          child: Text('Upload'))),
                  Visibility(
                      visible: readyToDownload,
                      child: ElevatedButton(
                          onPressed: onDownloadButtonPressed,
                          child: Text('Download'))),
                ]),
          )
        ])));
  }

  void onCommonTap(List<ARKitTestResult> hits) {
    /* // FC TODO CHECK
    this.arSessionManager.onPlaneOrPointTap = onPlaneOrPointTapped;
    this.arObjectManager.onNodeTap = onNodeTapped;
     */
    final planeHitTestResults = hits.where((e) => (e.type == ARKitHitTestResultType.existingPlaneUsingGeometry || e.type == ARKitHitTestResultType.existingPlaneUsingExtent)).toList();
    if (planeHitTestResults.isNotEmpty) {
      onPlaneOrPointTapped(planeHitTestResults);
    }

    final nodeHitTestResults = hits.where((e) => (e.type == ARKitHitTestResultType.featurePoint)).toList();
    if (nodeHitTestResults.isNotEmpty) {
      final nodeList = nodeHitTestResults.map((e) => e.anchor?.nodeName ?? e.anchor?.identifier ?? 'unknown').toList();
      onNodeTapped(nodeList);
    }
  }

  void onARKitViewCreated(
      ARKitController controller) {
    arController = controller;
    arAnchorManager = ARAnchorManager(controller.id);
    arLocationManager = ARLocationManager();
    arAnchorManager.initGoogleCloudAnchorMode();

    arController.onARTap = onCommonTap;
    arAnchorManager.onAnchorUploaded = onAnchorUploaded;
    arAnchorManager.onAnchorDownloaded = onAnchorDownloaded;

    arLocationManager
        .startLocationUpdates()
        .then((value) => null)
        .onError((error, stackTrace) {
      switch (error.toString()) {
        case 'Location services disabled':
          {
            showAlertDialog(
                context,
                'Action Required',
                'To use cloud anchor functionality, please enable your location services',
                'Settings',
                arLocationManager.openLocationServicesSettings,
                'Cancel');
            break;
          }

        case 'Location permissions denied':
          {
            showAlertDialog(
                context,
                'Action Required',
                "To use cloud anchor functionality, please allow the app to access your device's location",
                'Retry',
                arLocationManager.startLocationUpdates,
                'Cancel');
            break;
          }

        case 'Location permissions permanently denied':
          {
            showAlertDialog(
                context,
                'Action Required',
                "To use cloud anchor functionality, please allow the app to access your device's location",
                'Settings',
                arLocationManager.openAppPermissionSettings,
                'Cancel');
            break;
          }

        default:
          {
            // FC TODO
            // this.arSessionManager.onError(error.toString());
            break;
          }
      }
      // FC TODO
      // this.arSessionManager.onError(error.toString());
    });
  }

  Future<void> onRemoveEverything() async {
    anchors.forEach((anchor) {
      arAnchorManager.removeAnchor(anchor);
    });
    anchors = [];
    if (lastUploadedAnchor != '') {
      setState(() {
        readyToDownload = true;
        readyToUpload = false;
      });
    } else {
      setState(() {
        readyToDownload = true;
        readyToUpload = false;
      });
    }
  }

  Future<void> onNodeTapped(List<String> nodeNames) async {
    var foregroundNode =
        nodes.firstWhereOrNull((element) => element.name == nodeNames.first);
    // FC TODO
    // this.arSessionManager.onError(foregroundNode.data["onTapText"]);
  }

  Future<void> onPlaneOrPointTapped(
      List<ARKitTestResult> hitTestResults) async {
    var singleHitTestResult = hitTestResults.firstWhere(
        // (hitTestResult) => hitTestResult.type == ARKitHitTestResultType.plane); // FC TODO CHECK Estimated or Existing plane !?
        (hitTestResult) => hitTestResult.type == ARKitHitTestResultType.estimatedHorizontalPlane);
    if (singleHitTestResult != null) {
      var newAnchor = ARKitPlaneAnchor(Vector3.zero(), Vector3.zero(), '', '', singleHitTestResult.worldTransform, [], '', 2);
      var didAddAnchor = await arAnchorManager.addAnchor(newAnchor) ?? false;
      if (didAddAnchor) {
        anchors.add(newAnchor);
        // Add note to anchor
        var newNode = ARKitNode(
          scale: Vector3(0.2, 0.2, 0.2),
          position: Vector3(0.0, 0.0, 0.0),
          rotation: Vector4(1.0, 0.0, 0.0, 0.0),
            // FC TODO
            // type: NodeType.webGLB,
            // uri: "https://github.com/KhronosGroup/glTF-Sample-Models/raw/master/2.0/Duck/glTF-Binary/Duck.glb",
            // data: {"onTapText": "Ouch, that hurt!"}
        );

        await arController.add(newNode, parentNodeName: newAnchor.nodeName);
        nodes.add(newNode);
        setState(() {
          readyToUpload = true;
        });

        /*
        bool didAddNodeToAnchor = await this.arObjectManager.addNode(newNode, planeAnchor: newAnchor);
        if (didAddNodeToAnchor) {
          this.nodes.add(newNode);
          setState(() {
            readyToUpload = true;
          });
        } else {
          this.arSessionManager.onError("Adding Node to Anchor failed");
        }
         */
      } else {
        // FC TODO CHECK
        // this.arSessionManager.onError("Adding Anchor failed");
      }
    }
  }

  Future<void> onUploadButtonPressed() async {
    arAnchorManager.uploadAnchor(anchors.last);
    setState(() {
      readyToUpload = false;
    });
  }

  onAnchorUploaded(ARKitAnchor anchor) {
    // Upload anchor information to firebase
    firebaseManager.uploadAnchor(anchor,
        currentLocation: arLocationManager.currentLocation);
    // Upload child nodes to firebase
    if (anchor is ARKitPlaneAnchor) {
      anchor.childNodes.forEach((nodeName) => firebaseManager.uploadObject(
          nodes.firstWhereOrNull((element) => element.name == nodeName)));
    }
    setState(() {
      readyToDownload = true;
      readyToUpload = false;
    });

    // FC TODO CHECK
    // this.arSessionManager.onError("Upload successful");
  }

  ARKitAnchor onAnchorDownloaded(Map<String, dynamic> serializedAnchor) {
    final anchor = ARKitPlaneAnchor.fromJson(
        anchorsInDownloadProgress[serializedAnchor['cloudanchorid']]);
    anchorsInDownloadProgress.remove(anchor.cloudanchorid);
    anchors.add(anchor);

    // Download nodes attached to this anchor
    firebaseManager.getObjectsFromAnchor(anchor, (snapshot) {
      snapshot.docs.forEach((objectDoc) {
        var object = ARKitNode.fromMap(objectDoc.data() as Map<String, dynamic>);
        arController.add(object, parentNodeName: anchor.nodeName);
        nodes.add(object);
      });
    });

    return anchor;
  }

  Future<void> onDownloadButtonPressed() async {
    //this.arAnchorManager.downloadAnchor(lastUploadedAnchor);
    //firebaseManager.downloadLatestAnchor((snapshot) {
    //  final cloudAnchorId = snapshot.docs.first.get("cloudanchorid");
    //  anchorsInDownloadProgress[cloudAnchorId] = snapshot.docs.first.data();
    //  arAnchorManager.downloadAnchor(cloudAnchorId);
    //});

    // Get anchors within a radius of 100m of the current device's location
    if (arLocationManager.currentLocation != null) {
      firebaseManager.downloadAnchorsByLocation((snapshot) {
        final cloudAnchorId = snapshot.get('cloudanchorid');
        anchorsInDownloadProgress[cloudAnchorId] = snapshot.data();
        arAnchorManager.downloadAnchor(cloudAnchorId);
      }, arLocationManager.currentLocation, 0.1);
      setState(() {
        readyToDownload = false;
      });
    } else {
      // FC TODO CHECK
      // this.arSessionManager.onError("Location updates not running, can't download anchors");
    }
  }

  void showAlertDialog(BuildContext context, String title, String content,
      String buttonText, Function buttonFunction, String cancelButtonText) {
    // set up the buttons
    Widget cancelButton = ElevatedButton(
      child: Text(cancelButtonText),
      onPressed: () {
        Navigator.of(context).pop();
      },
    );
    Widget actionButton = ElevatedButton(
      child: Text(buttonText),
      onPressed: () {
        buttonFunction();
        Navigator.of(context).pop();
      },
    );

    // set up the AlertDialog
    AlertDialog alert = AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        cancelButton,
        actionButton,
      ],
    );

    // show the dialog
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return alert;
      },
    );
  }
}

// Class for managing interaction with Firebase (in your own app, this can be put in a separate file to keep everything clean and tidy)
typedef FirebaseListener = void Function(QuerySnapshot snapshot);
typedef FirebaseDocumentStreamListener = void Function(
    DocumentSnapshot snapshot);

class FirebaseManager {
  late FirebaseFirestore firestore;
  late Geoflutterfire geo;
  late CollectionReference anchorCollection;
  late CollectionReference objectCollection;

  // Firebase initialization function
  Future<bool> initializeFlutterFire() async {
    try {
      // Wait for Firebase to initialize
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      geo = Geoflutterfire();
      firestore = FirebaseFirestore.instance;
      anchorCollection = FirebaseFirestore.instance.collection('anchors');
      objectCollection = FirebaseFirestore.instance.collection('objects');
      return true;
    } catch (e) {
      return false;
    }
  }

  void uploadAnchor(ARKitAnchor anchor, {Position? currentLocation}) {
    if (firestore == null) return;

    var serializedAnchor = anchor.toJson();
    var expirationTime = DateTime.now().millisecondsSinceEpoch / 1000 +
        serializedAnchor['ttl'] * 24 * 60 * 60;
    serializedAnchor['expirationTime'] = expirationTime;
    // Add location
    if (currentLocation != null) {
      GeoFirePoint myLocation = geo.point(
          latitude: currentLocation.latitude,
          longitude: currentLocation.longitude);
      serializedAnchor['position'] = myLocation.data;
    }

    anchorCollection
        .add(serializedAnchor)
        .then((value) =>
            print('Successfully added anchor: ' + serializedAnchor['name']))
        .catchError((error) => print('Failed to add anchor: $error'));
  }

  void uploadObject(ARKitNode? node) {
    if (firestore == null) return;

    var serializedNode = node!.toMap();

    objectCollection
        .add(serializedNode)
        .then((value) =>
            print('Successfully added object: ' + serializedNode['name']))
        .catchError((error) => print('Failed to add object: $error'));
  }

  void downloadLatestAnchor(FirebaseListener listener) {
    anchorCollection
        .orderBy('expirationTime', descending: false)
        .limitToLast(1)
        .get()
        .then((value) => listener(value))
        .catchError(
            (error) => (error) => print('Failed to download anchor: $error'));
  }

  void downloadAnchorsByLocation(FirebaseDocumentStreamListener listener,
      Position location, double radius) {
    GeoFirePoint center =
        geo.point(latitude: location.latitude, longitude: location.longitude);

    Stream<List<DocumentSnapshot>> stream = geo
        .collection(collectionRef: anchorCollection)
        .within(center: center, radius: radius, field: 'position');

    stream.listen((List<DocumentSnapshot> documentList) {
      documentList.forEach((element) {
        listener(element);
      });
    });
  }

  void downloadAnchorsByChannel() {}

  void getObjectsFromAnchor(ARKitPlaneAnchor anchor, FirebaseListener listener) {
    objectCollection
        .where('name', whereIn: anchor.childNodes)
        .get()
        .then((value) => listener(value))
        .catchError((error) => print('Failed to download objects: $error'));
  }

  void deleteExpiredDatabaseEntries() {
    WriteBatch batch = FirebaseFirestore.instance.batch();
    anchorCollection
        .where('expirationTime',
            isLessThan: DateTime.now().millisecondsSinceEpoch / 1000)
        .get()
        .then((anchorSnapshot) => anchorSnapshot.docs.forEach((anchorDoc) {
              // Delete all objects attached to the expired anchor
              objectCollection
                  .where('name', arrayContainsAny: anchorDoc.get('childNodes'))
                  .get()
                  .then((objectSnapshot) => objectSnapshot.docs.forEach(
                      (objectDoc) => batch.delete(objectDoc.reference)));
              // Delete the expired anchor
              batch.delete(anchorDoc.reference);
            }));
    batch.commit();
  }
}
