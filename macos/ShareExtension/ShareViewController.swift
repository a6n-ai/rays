import Cocoa
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await send() }
    }

    private func send() async {
        var links: [String] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier),
               let url = (item as? URL) ?? (item as? String).flatMap(URL.init(string:)) {
                links.append(url.absoluteString)
            } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
                      let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let u = m.url { links.append(u.absoluteString) }
                }
            }
        }
        var c = URLComponents()
        c.scheme = "rays"
        c.host = "add"
        c.queryItems = links.filter { $0.lowercased().hasPrefix("http") }.map { URLQueryItem(name: "url", value: $0) }
        if let url = c.url, c.queryItems?.isEmpty == false {
            NSWorkspace.shared.open(url)
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
