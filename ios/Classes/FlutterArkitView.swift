import Foundation
import UIKit
import Foundation
import ARKit
import Combine
import ARCoreCloudAnchors

class FlutterArkitView: NSObject, FlutterPlatformView, ARSessionDelegate {
    let sceneView: ARSCNView
    let channel: FlutterMethodChannel
    let anchorManagerChannel: FlutterMethodChannel

    var forceTapOnCenter: Bool = false
    var configuration: ARConfiguration? = nil

    private var cloudAnchorHandler: CloudAnchorHandler? = nil
    var anchorCollection = [String: ARAnchor]() //Used to bookkeep all anchors created by Flutter calls
    private var arcoreSession: GARSession? = nil
    private var arcoreMode: Bool = false
    private var configurationTracking: ARWorldTrackingConfiguration!
    let modelBuilder = ArModelBuilder()
    var cancellableCollection = Set<AnyCancellable>() //Used to store all cancellables in (needed for working with Futures)

    init(withFrame frame: CGRect, viewIdentifier viewId: Int64, messenger msg: FlutterBinaryMessenger) {
        self.sceneView = ARSCNView(frame: frame)
        self.channel = FlutterMethodChannel(name: "arkit_\(viewId)", binaryMessenger: msg)
        self.anchorManagerChannel = FlutterMethodChannel(name: "aranchors_\(viewId)", binaryMessenger: msg)

        super.init()
        
        let configurationTracking = ARWorldTrackingConfiguration() // Create default configuration before initializeARView is called
        self.sceneView.delegate = self
        self.sceneView.session.run(configurationTracking)
        self.sceneView.session.delegate = self

        self.channel.setMethodCallHandler(self.onMethodCalled)
        self.anchorManagerChannel.setMethodCallHandler(self.onAnchorMethodCalled)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if (arcoreMode) {
            do {
                try arcoreSession!.update(frame)
            } catch {
                print(error)
            }
        }
    }


    func view() -> UIView { return sceneView }
    
    func onMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>
        
        if configuration == nil && call.method != "init" {
            logPluginError("plugin is not initialized properly", toChannel: channel)
            result(nil)
            return
        }
        
        switch call.method {
        case "init":
            initalize(arguments!, result)
            result(nil)
            break
        case "addARKitNode":
            onAddNode(arguments!)
            result(nil)
            break
        case "onUpdateNode":
            onUpdateNode(arguments!)
            result(nil)
            break
        case "removeARKitNode":
            onRemoveNode(arguments!)
            result(nil)
            break
        case "removeARKitAnchor":
            onRemoveAnchor(arguments!)
            result(nil)
            break
        case "addCoachingOverlay":
            if #available(iOS 13.0, *) {
              addCoachingOverlay(arguments!)
            }
            result(nil)
            break
        case "removeCoachingOverlay":
            if #available(iOS 13.0, *) {
              removeCoachingOverlay()
            }
            result(nil)
            break
        case "getNodeBoundingBox":
            onGetNodeBoundingBox(arguments!, result)
            break
        case "transformationChanged":
            onTransformChanged(arguments!)
            result(nil)
            break
        case "isHiddenChanged":
            onIsHiddenChanged(arguments!)
            result(nil)
            break
        case "updateSingleProperty":
            onUpdateSingleProperty(arguments!)
            result(nil)
            break
        case "updateMaterials":
            onUpdateMaterials(arguments!)
            result(nil)
            break
        case "performHitTest":
            onPerformHitTest(arguments!, result)
            break
        case "updateFaceGeometry":
            onUpdateFaceGeometry(arguments!)
            result(nil)
            break
        case "getLightEstimate":
            onGetLightEstimate(result)
            result(nil)
            break
        case "projectPoint":
            onProjectPoint(arguments!, result)
            break
        case "cameraProjectionMatrix":
            onCameraProjectionMatrix(result)
            break
        case "pointOfViewTransform":
            onPointOfViewTransform(result)
            break
        case "playAnimation":
            onPlayAnimation(arguments!)
            result(nil)
            break
        case "stopAnimation":
            onStopAnimation(arguments!)
            result(nil)
            break
        case "dispose":
            onDispose(result)
            result(nil)
            break
        case "cameraEulerAngles":
            onCameraEulerAngles(result)
            break
        case "snapshot":
            onGetSnapshot(result)
            break
        case "addNodeToPlaneAnchor":
            if let dict_node = arguments!["node"] as? Dictionary<String, Any>, let dict_anchor = arguments!["anchor"] as? Dictionary<String, Any> {
                addNode(dict_node: dict_node, dict_anchor: dict_anchor).sink(receiveCompletion: {completion in }, receiveValue: { val in
                       result(val)
                    }).store(in: &self.cancellableCollection)
            }
            break
        default:
            result(FlutterMethodNotImplemented)
            break
        }
    }

    func addPlaneAnchor(transform: Array<NSNumber>, name: String){
        let arAnchor = ARAnchor(transform: simd_float4x4(deserializeMatrix4(transform)))
        anchorCollection[name] = arAnchor
        sceneView.session.add(anchor: arAnchor)
        // Ensure root node is added to anchor before any other function can run (if this isn't done, addNode could fail because anchor does not have a root node yet).
        // The root node is added to the anchor as soon as the async rendering loop runs once, more specifically the function "renderer(_:nodeFor:)"
        while (sceneView.node(for: arAnchor) == nil) {
            usleep(1) // wait 1 millionth of a second
        }
    }

    func deleteAnchor(anchorName: String) {
        if let anchor = anchorCollection[anchorName]{
            // Delete all child nodes
            if var attachedNodes = sceneView.node(for: anchor)?.childNodes {
                attachedNodes.removeAll()
            }
            // Remove anchor
            sceneView.session.remove(anchor: anchor)
            // Update bookkeeping
            anchorCollection.removeValue(forKey: anchorName)
        }
    }

    private class cloudAnchorUploadedListener: CloudAnchorListener {
        private var parent: FlutterArkitView

        init(parent: FlutterArkitView) {
            self.parent = parent
        }

        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    var args = Dictionary<String, String?>()
                    args["name"] = anchorName
                    args["cloudanchorid"] = anchor?.cloudIdentifier
                    parent.anchorManagerChannel.invokeMethod("onCloudAnchorUploaded", arguments: args)
                } else {
                    print("Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))")
                    // FC TODO parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))"])
                    parent.anchorManagerChannel.invokeMethod("onError", arguments: ["Error uploading anchor, state: \(parent.decodeCloudAnchorState(state: cloudState))"])
                    return
                }
            }
        }
    }

    private class cloudAnchorDownloadedListener: CloudAnchorListener {
        private var parent: FlutterArkitView

        init(parent: FlutterArkitView) {
            self.parent = parent
        }

        func onCloudTaskComplete(anchorName: String?, anchor: GARAnchor?) {
            if let cloudState = anchor?.cloudState {
                if (cloudState == GARCloudAnchorState.success) {
                    let newAnchor = ARAnchor(transform: anchor!.transform)
                    // Register new anchor on the Flutter side of the plugin
                    self.parent.anchorManagerChannel.invokeMethod("onAnchorDownloadSuccess", arguments: serializeCloudAnchor(anchor: newAnchor, anchorNode: nil, ganchor: anchor!, name: anchorName), result: { result in
                        if let anchorName = result as? String {
                            self.parent.sceneView.session.add(anchor: newAnchor)
                            self.parent.anchorCollection[anchorName] = newAnchor
                        } else {
                            // FC TODO self.parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error while registering downloaded anchor at the AR Flutter plugin Light"])
                            self.parent.anchorManagerChannel.invokeMethod("onError", arguments: ["Error while registering downloaded anchor at the AR Flutter plugin Light"])
                        }

                    })
                } else {
                    print("Error downloading anchor, state \(cloudState)")
                    // FC TODO parent.sessionManagerChannel.invokeMethod("onError", arguments: ["Error downloading anchor, state \(cloudState)"])
                    self.parent.anchorManagerChannel.invokeMethod("onError", arguments: ["Error downloading anchor, state \(cloudState)"])
                    return
                }
            }
        }
    }

    func decodeCloudAnchorState(state: GARCloudAnchorState) -> String {
        switch state {
        case .errorCloudIdNotFound:
            return "Cloud anchor id not found"
        case .errorHostingDatasetProcessingFailed:
            return "Dataset processing failed, feature map insufficient"
        case .errorHostingServiceUnavailable:
            return "Hosting service unavailable"
        case .errorInternal:
            return "Internal error"
        case .errorNotAuthorized:
            return "Authentication failed: Not Authorized"
        case .errorResolvingSdkVersionTooNew:
            return "Resolving Sdk version too new"
        case .errorResolvingSdkVersionTooOld:
            return "Resolving Sdk version too old"
        case .errorResourceExhausted:
            return " Resource exhausted"
        case .none:
            return "Empty state"
        case .taskInProgress:
            return "Task in progress"
        case .success:
            return "Success"
        case .errorServiceUnavailable:
            return "Cloud Anchor Service unavailable"
        case .errorResolvingLocalizationNoMatch:
            return "No match"
        @unknown default:
            return "Unknown"
        }
    }

    func onAnchorMethodCalled(_ call :FlutterMethodCall, _ result: @escaping FlutterResult) {
        let arguments = call.arguments as? Dictionary<String, Any>

        switch call.method {
            case "init":
                // FC TODO self.objectManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])
                self.anchorManagerChannel.invokeMethod("onError", arguments: ["ObjectTEST from iOS"])
                result(nil)
                break
            case "addAnchor":
                if let type = arguments!["type"] as? Int {
                    switch type {
                    case 0: //Plane Anchor
                        if let transform = arguments!["transform"] as? Array<NSNumber>, let name = arguments!["name"] as? String {
                            addPlaneAnchor(transform: transform, name: name)
                            result(true)
                        }
                        print("FC SWIFT - addAnchor with wrong arguments: \(arguments)")
                        result(false)
                        break
                    default:
                        print("FC SWIFT - addAnchor with wrong type: \(type)")
                        result(false)

                    }
                }
                print("FC SWIFT - addAnchor without type argument")
                result(nil)
                break
            case "removeAnchor":
                if let name = arguments!["name"] as? String {
                    deleteAnchor(anchorName: name)
                }
                break
            case "initGoogleCloudAnchorMode":
                arcoreSession = try! GARSession.session()
                if (arcoreSession != nil){
                    let configuration = GARSessionConfiguration();
                    configuration.cloudAnchorMode = .enabled;
                    arcoreSession?.setConfiguration(configuration, error: nil);
                    if let token = JWTGenerator().generateWebToken(){
                        arcoreSession!.setAuthToken(token)

                        cloudAnchorHandler = CloudAnchorHandler(session: arcoreSession!)
                        arcoreSession!.delegate = cloudAnchorHandler
                        arcoreSession!.delegateQueue = DispatchQueue.main

                        arcoreMode = true
                    } else {
                        // FC TODO sessionManagerChannel.invokeMethod("onError", arguments: ["Error generating JWT, have you added cloudAnchorKey.json into the example/ios/Runner directory?"])
                        print ("FC SWIFT ERROR: Error generating JWT, have you added cloudAnchorKey.json into the example/ios/Runner directory?")
                        anchorManagerChannel.invokeMethod("onError", arguments: ["Error generating JWT, have you added cloudAnchorKey.json into the example/ios/Runner directory?"])
                    }
                } else {
                    // FC TODO sessionManagerChannel.invokeMethod("onError", arguments: ["Error initializing Google AR Session"])
                    print ("FC SWIFT ERROR: Error initializing Google AR Session")
                    anchorManagerChannel.invokeMethod("onError", arguments: ["Error initializing Google AR Session"])
                }

                break
            case "uploadAnchor":
                if let anchorName = arguments!["nodeName"] as? String, let anchor = anchorCollection[anchorName] {
                    print("---------------- HOSTING INITIATED ------------------")
                    if let ttl = arguments!["ttl"] as? Int {
                        cloudAnchorHandler?.hostCloudAnchorWithTtl(anchorName: anchorName, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self), ttl: ttl)
                    } else {
                        cloudAnchorHandler?.hostCloudAnchor(anchorName: anchorName, anchor: anchor, listener: cloudAnchorUploadedListener(parent: self))
                    }
                }
                result(true)
                break
            case "downloadAnchor":
                if let anchorId = arguments!["cloudanchorid"] as? String {
                    print("---------------- RESOLVING INITIATED ------------------")
                    cloudAnchorHandler?.resolveCloudAnchor(anchorId: anchorId, listener: cloudAnchorDownloadedListener(parent: self))
                }
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }

    func onDispose(_ result:FlutterResult) {
        sceneView.session.pause()
        self.channel.setMethodCallHandler(nil)
        self.anchorManagerChannel.setMethodCallHandler(nil)
        result(nil)
    }
}
