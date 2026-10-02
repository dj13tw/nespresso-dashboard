import SwiftUI
import WallPainterCore

struct PaletteView: View {
    @Binding var selection: PaintColor
    @StateObject private var favorites = FavoriteColors()
    @State private var customColor = Palette.defaultColor.color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selection.color)
                    .frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.2)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(selection.name).font(.headline)
                    Text(selection.rgb.hex).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    favorites.toggle(selection)
                } label: {
                    Image(systemName: favorites.contains(selection) ? "star.fill" : "star")
                        .font(.title3)
                }
                .accessibilityLabel(favorites.contains(selection) ? "從我的顏色移除" : "加入我的顏色")
                ColorPicker("自訂顏色", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    if !favorites.colors.isEmpty {
                        SwatchGroup(title: "我的顏色", colors: favorites.colors, selection: $selection)
                    }
                    ForEach(Palette.groups) { group in
                        SwatchGroup(title: group.name, colors: group.colors, selection: $selection)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .onChange(of: customColor) { _, newValue in
            let rgb = RGB(newValue)
            if rgb != selection.rgb {
                selection = PaintColor(name: "自訂 \(rgb.hex)", rgb: rgb)
            }
        }
    }
}

private struct SwatchGroup: View {
    let title: String
    let colors: [PaintColor]
    @Binding var selection: PaintColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(colors) { paint in
                    Button {
                        selection = paint
                    } label: {
                        Circle()
                            .fill(paint.color)
                            .frame(width: 40, height: 40)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .padding(-4)
                                    .opacity(paint.rgb == selection.rgb ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(paint.name)
                }
            }
            .padding(4)
        }
    }
}
