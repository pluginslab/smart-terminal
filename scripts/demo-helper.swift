// Helpers for scripts/record-demo.sh, compiled once so each call is instant.
//   demo-helper post <channel-id> <cmd> [args...]   debug command (like scripts/debug.sh)
//   demo-helper save <file> | restore <file>         the whole clipboard, every item and type
//   demo-helper image <png>                          copy an image, like a screenshot to clipboard
//   demo-helper bounds <pid>                         x,y,w,h of that process's largest window
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
let pb = NSPasteboard.general

switch args.first {
case "post":
    let payload = args.dropFirst(2).joined(separator: "\u{1F}")
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.pluginslab.smartterminal.debug.\(args[1])"), object: payload, userInfo: nil, deliverImmediately: true)
case "save":
    let items: [[String: Data]] = (pb.pasteboardItems ?? []).map { item in
        Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t.rawValue, $0) } })
    }
    try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
        .write(to: URL(fileURLWithPath: args[1]))
case "restore":
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let items = try PropertyListSerialization.propertyList(from: data, format: nil) as! [[String: Data]]
    pb.clearContents()
    pb.writeObjects(items.map { d in
        let item = NSPasteboardItem()
        d.forEach { item.setData($1, forType: .init($0)) }
        return item
    })
case "image":
    pb.clearContents()
    pb.setData(try Data(contentsOf: URL(fileURLWithPath: args[1])), forType: .png)
case "bounds":
    let pid = Int32(args[1])!
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let frames = list.filter { ($0["kCGWindowOwnerPID"] as? Int32) == pid && ($0["kCGWindowLayer"] as? Int) == 0 }
        .compactMap { ($0["kCGWindowBounds"] as? [String: CGFloat]) }
    if let b = frames.max(by: { ($0["Width"]! * $0["Height"]!) < ($1["Width"]! * $1["Height"]!) }) {
        print("\(Int(b["X"]!)),\(Int(b["Y"]!)),\(Int(b["Width"]!)),\(Int(b["Height"]!))")
    }
default:
    FileHandle.standardError.write("usage: demo-helper post|save|restore|image|bounds …\n".data(using: .utf8)!)
    exit(1)
}
