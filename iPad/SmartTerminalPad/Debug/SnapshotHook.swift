#if DEBUG
import UIKit

/// Screenshots of the app on a real iPad, from the Mac, for debug builds only.
/// iPadOS 26 has no USB screenshot service any more, so the app takes its own:
/// copy a file named `snap-request` into its Documents, and it writes `snap.png`
/// there within a second.
///
///     xcrun devicectl device copy to   --device <id> --domain-type appDataContainer \
///         --domain-identifier com.pluginslab.smartterminal.pad --source req --destination Documents/snap-request
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///         --domain-identifier com.pluginslab.smartterminal.pad --source Documents/snap.png --destination snap.png
@MainActor
enum SnapshotHook {
    static func start() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let request = docs.appendingPathComponent("snap-request")
        let output = docs.appendingPathComponent("snap.png")
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard FileManager.default.fileExists(atPath: request.path) else { continue }
                try? FileManager.default.removeItem(at: request)
                guard let window = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { continue }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try? image.pngData()?.write(to: output)
            }
        }
    }
}
#endif
