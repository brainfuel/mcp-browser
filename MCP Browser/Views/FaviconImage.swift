//
//  FaviconImage.swift
//  MCP Browser
//
//  Renders the favicon for a URL via the shared `FaviconService`,
//  falling back to the generic globe glyph while a fetch is in
//  flight or when no host can be resolved.
//

import SwiftUI

struct FaviconImage: View {
    @Environment(FaviconService.self) private var favicons

    let urlString: String
    var size: CGFloat = 16

    var body: some View {
        if let icon = favicons.icon(for: urlString) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.medium)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
