import AppKit
import PencilKit
import SwiftUI

// MARK: - 导出 PNG

extension MacAppModel {
    func exportCurrent() {
        guard let id = selectedPageID else { return }
        exportPage(id)
    }

    func exportPage(_ id: UUID) {
        guard let meta = store.pageMeta(id) else { return }
        guard
            let rendered = PageRenderer.composite(
                drawing: store.drawing(id),
                background: store.bgImage(id),
                pageSize: meta.pageSize,
                padding: 0,
                scale: 2,
                fillWhite: true
            )
        else {
            NSSound.beep()
            return
        }
        guard let tiff = rendered.image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(meta.name).png"
        panel.message = "将“\(meta.name)”导出为 PNG 图片"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
