import SceneKit
import SwiftUI

/// Embeds an interactive SceneKit viewport in a SwiftUI view.
/// Supports orbit rotation, zoom, and renders a scene from a JSON description.
struct SceneKitNodeView: NSViewRepresentable {
    let sceneDescription: SceneDescription

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = buildScene(from: sceneDescription)
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = .clear
        scnView.antialiasingMode = .multisampling4X
        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    private func buildScene(from desc: SceneDescription) -> SCNScene {
        let scene = SCNScene()

        // Camera
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.1
        camera.zFar = 200
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let camDist = desc.cameraDistance ?? 5.0
        cameraNode.position = SCNVector3(camDist * 0.6, camDist * 0.4, camDist)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        // Lighting
        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light!.type = .directional
        keyLight.light!.intensity = 800
        keyLight.light!.color = NSColor.white
        keyLight.light!.castsShadow = true
        keyLight.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light!.type = .directional
        fillLight.light!.intensity = 300
        fillLight.light!.color = NSColor(white: 0.9, alpha: 1)
        fillLight.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillLight)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 200
        ambient.light!.color = NSColor(white: 0.6, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        // Floor (optional)
        if desc.showFloor ?? false {
            let floor = SCNFloor()
            floor.reflectivity = 0.05
            floor.firstMaterial?.diffuse.contents = NSColor(white: 0.15, alpha: 1)
            let floorNode = SCNNode(geometry: floor)
            floorNode.position = SCNVector3(0, -0.5, 0)
            scene.rootNode.addChildNode(floorNode)
        }

        // Objects
        for obj in desc.objects {
            let node = buildObject(obj)
            scene.rootNode.addChildNode(node)
        }

        return scene
    }

    private func buildObject(_ obj: SceneObject) -> SCNNode {
        let geometry: SCNGeometry

        switch obj.shape {
        case .sphere:
            geometry = SCNSphere(radius: CGFloat(obj.size ?? 1.0))
        case .box:
            let s = CGFloat(obj.size ?? 1.0)
            geometry = SCNBox(width: s, height: s, length: s, chamferRadius: CGFloat(obj.chamfer ?? 0.05))
        case .cylinder:
            geometry = SCNCylinder(radius: CGFloat(obj.size ?? 0.5), height: CGFloat(obj.height ?? 2.0))
        case .cone:
            geometry = SCNCone(topRadius: 0, bottomRadius: CGFloat(obj.size ?? 0.5), height: CGFloat(obj.height ?? 2.0))
        case .torus:
            geometry = SCNTorus(ringRadius: CGFloat(obj.size ?? 1.0), pipeRadius: CGFloat(obj.pipeRadius ?? 0.3))
        case .plane:
            let s = CGFloat(obj.size ?? 2.0)
            geometry = SCNPlane(width: s, height: s)
        case .pyramid:
            let s = CGFloat(obj.size ?? 1.0)
            let h = CGFloat(obj.height ?? obj.size ?? 1.0)
            geometry = SCNPyramid(width: s, height: h, length: s)
        case .capsule:
            geometry = SCNCapsule(capRadius: CGFloat(obj.size ?? 0.3), height: CGFloat(obj.height ?? 2.0))
        case .tube:
            geometry = SCNTube(
                innerRadius: CGFloat((obj.size ?? 0.8) * 0.6),
                outerRadius: CGFloat(obj.size ?? 0.8),
                height: CGFloat(obj.height ?? 2.0)
            )
        case .text3D:
            let text = SCNText(string: obj.textContent ?? "Hello", extrusionDepth: CGFloat(obj.extrusionDepth ?? 0.3))
            text.font = NSFont.systemFont(ofSize: CGFloat(obj.size ?? 1.0), weight: .medium)
            text.flatness = 0.1
            geometry = text
        }

        // Material
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased

        if let hex = obj.color {
            material.diffuse.contents = NSColor(hex: hex)
        } else {
            material.diffuse.contents = NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.9, alpha: 1)
        }

        material.metalness.contents = NSNumber(value: obj.metalness ?? 0.3)
        material.roughness.contents = NSNumber(value: obj.roughness ?? 0.4)

        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(
            obj.position?.x ?? 0,
            obj.position?.y ?? 0,
            obj.position?.z ?? 0
        )

        if let rot = obj.rotation {
            node.eulerAngles = SCNVector3(
                Float(rot.x ?? 0) * .pi / 180,
                Float(rot.y ?? 0) * .pi / 180,
                Float(rot.z ?? 0) * .pi / 180
            )
        }

        return node
    }
}

// MARK: - Scene Description Model

/// JSON-decodable description of a 3D scene. The AI generates this,
/// and SceneKitNodeView renders it interactively.
struct SceneDescription: Codable, Equatable {
    var objects: [SceneObject]
    var cameraDistance: Float?
    var showFloor: Bool?
}

struct SceneObject: Codable, Equatable {
    var shape: ShapeType
    var size: Float?
    var height: Float?
    var chamfer: Float?
    var pipeRadius: Float?
    var extrusionDepth: Float?
    var textContent: String?
    var color: String?       // hex like "#4499DD"
    var metalness: Float?
    var roughness: Float?
    var position: Vec3?
    var rotation: Vec3?

    enum ShapeType: String, Codable {
        case sphere, box, cylinder, cone, torus, plane, pyramid, capsule, tube, text3D
    }
}

struct Vec3: Codable, Equatable {
    var x: Float?
    var y: Float?
    var z: Float?
}

// MARK: - NSColor hex helper

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
