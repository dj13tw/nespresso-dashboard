import SwiftUI
import WallPainterCore

struct PaintColor: Identifiable, Hashable, Codable {
    var name: String
    var rgb: RGB

    var id: String { rgb.hex }
    var color: Color { rgb.color }

    init(_ name: String, _ hex: String) {
        self.name = name
        rgb = RGB(hex: hex) ?? RGB(r: 128, g: 128, b: 128)
    }

    init(name: String, rgb: RGB) {
        self.name = name
        self.rgb = rgb
    }
}

struct PaletteGroup: Identifiable {
    let name: String
    let colors: [PaintColor]
    var id: String { name }
}

/// Popular interior paint tones. Generic names, not tied to any paint brand.
enum Palette {
    static let groups: [PaletteGroup] = [
        PaletteGroup(name: "白與米色", colors: [
            PaintColor("象牙白", "#F2EDE3"), PaintColor("奶油白", "#EFE6D2"), PaintColor("燕麥色", "#DCCFB8"),
            PaintColor("亞麻色", "#D8C8AE"), PaintColor("沙丘米", "#CDB99A"),
        ]),
        PaletteGroup(name: "灰色", colors: [
            PaintColor("霧灰", "#C9C9C4"), PaintColor("暖灰", "#B5ADA3"), PaintColor("水泥灰", "#9A9A96"),
            PaintColor("石板灰", "#6E7275"), PaintColor("炭灰", "#45484B"),
        ]),
        PaletteGroup(name: "綠色", colors: [
            PaintColor("鼠尾草綠", "#A3B49A"), PaintColor("抹茶綠", "#8FA58A"), PaintColor("薄荷綠", "#BFD8C8"),
            PaintColor("橄欖綠", "#7A7D52"), PaintColor("森林綠", "#3F5B47"),
        ]),
        PaletteGroup(name: "藍色", colors: [
            PaintColor("霧藍", "#A9BCC8"), PaintColor("灰藍", "#7D93A3"), PaintColor("湖水藍", "#6F9FA6"),
            PaintColor("海軍藍", "#2F4A5E"), PaintColor("靛青", "#2B3A55"),
        ]),
        PaletteGroup(name: "大地暖色", colors: [
            PaintColor("奶茶色", "#C8A98C"), PaintColor("乾燥玫瑰", "#C49A97"), PaintColor("芥末黃", "#D2A84A"),
            PaintColor("赤陶", "#B5654A"), PaintColor("焦糖", "#A0683F"),
        ]),
        PaletteGroup(name: "深色", colors: [
            PaintColor("墨綠", "#2E3D36"), PaintColor("午夜藍", "#1F2A3A"), PaintColor("深咖啡", "#4A3A31"),
            PaintColor("石墨黑", "#2A2A2A"),
        ]),
    ]

    static let defaultColor = groups[2].colors[0]
}

/// Colors the user starred, kept across launches.
final class FavoriteColors: ObservableObject {
    private static let key = "favoriteColors"

    @Published private(set) var colors: [PaintColor]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key) ?? Data()
        colors = (try? JSONDecoder().decode([PaintColor].self, from: data)) ?? []
    }

    func contains(_ color: PaintColor) -> Bool { colors.contains { $0.rgb == color.rgb } }

    func toggle(_ color: PaintColor) {
        if contains(color) {
            colors.removeAll { $0.rgb == color.rgb }
        } else {
            colors.insert(color, at: 0)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(colors), forKey: Self.key)
    }
}
