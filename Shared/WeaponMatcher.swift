import Foundation
import Vision
import CoreVideo
import UIKit

/// 用 Vision 的图像特征向量做武器图标匹配。
///
/// 不需要训练：VNGenerateImageFeaturePrintRequest 对每张图产出一个
/// 特征向量，同武器图标之间距离小、不同武器之间距离大。模板由用户在
/// 游戏里现场抓帧制作，所以不依赖任何预设素材。
final class WeaponMatcher {

    private struct Template {
        let id: String
        let featurePrint: VNFeaturePrintObservation
    }

    private var templates: [Template] = []
    private let request = VNGenerateImageFeaturePrintRequest()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 距离阈值：超过这个值认为是"没识别出来"，避免硬匹配到最像的那把枪。
    public var maxDistance: Float = 14.0

    public private(set) var templateCount: Int = 0

    // MARK: - 模板

    /// 从 App Group 的 templates 目录加载。
    /// 文件名即武器 id，例：M416.fp / AKM.fp
    @discardableResult
    public func loadTemplates() -> Int {
        guard let dir = SharedStore.containerURL?.appendingPathComponent("templates", isDirectory: true) else {
            return 0
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        var loaded: [Template] = []
        for file in files where file.pathExtension == "fp" {
            guard let data = try? Data(contentsOf: file),
                  let print = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: VNFeaturePrintObservation.self, from: data)
            else { continue }
            loaded.append(Template(id: file.deletingPathExtension().lastPathComponent,
                                   featurePrint: print))
        }
        templates = loaded
        templateCount = loaded.count
        return loaded.count
    }

    /// 从一张整帧截图生成模板特征并存盘。region 是归一化 ROI。
    @discardableResult
    public func makeTemplate(from image: UIImage, id: String, region: CGRect) -> Bool {
        guard let cg = image.cgImage else { return false }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let crop = CGRect(x: region.minX * width,
                          y: region.minY * height,
                          width: region.width * width,
                          height: region.height * height)
        guard let cropped = cg.cropping(to: crop) else { return false }

        // request 是复用的，上一次 match 设过的 regionOfInterest 会残留；
        // 这里喂进去的已经是裁好的图，必须重置回整图，否则会二次裁切。
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do { try handler.perform([request]) } catch { return false }
        guard let obs = request.results?.first as? VNFeaturePrintObservation else { return false }
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: obs,
                                                           requiringSecureCoding: true)
        else { return false }

        guard let dir = SharedStore.containerURL?.appendingPathComponent("templates", isDirectory: true)
        else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: dir.appendingPathComponent("\(id).fp"), options: .atomic)
        } catch {
            return false
        }
        return loadTemplates() > 0
    }

    public func removeAllTemplates() {
        guard let dir = SharedStore.containerURL?.appendingPathComponent("templates", isDirectory: true)
        else { return }
        try? FileManager.default.removeItem(at: dir)
        templates = []
        templateCount = 0
    }

    // MARK: - 匹配

    /// 在整帧里按 ROI 取武器图标并匹配。返回 (武器 id, 距离)。
    public func match(pixelBuffer: CVPixelBuffer, region: CGRect) -> (id: String, distance: Float)? {
        guard !templates.isEmpty else { return nil }

        request.regionOfInterest = region
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let obs = request.results?.first as? VNFeaturePrintObservation else { return nil }

        var bestID: String?
        var bestDistance = Float.greatestFiniteMagnitude
        for template in templates {
            var distance: Float = 0
            guard (try? obs.computeDistance(&distance, to: template.featurePrint)) != nil else { continue }
            if distance < bestDistance {
                bestDistance = distance
                bestID = template.id
            }
        }

        guard let id = bestID, bestDistance <= maxDistance else { return nil }
        return (id, bestDistance)
    }
}
