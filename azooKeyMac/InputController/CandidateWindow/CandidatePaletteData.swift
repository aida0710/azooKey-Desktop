// Generated from Shared/CandidatePalettes.json. Run Tools/generate-candidate-palettes.py.
import AppKit

@MainActor
struct CandidatePalette {
    let background: NSColor
    let surface: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let border: NSColor
    let selection: NSColor
    let selectionText: NSColor
    let scoreLow: NSColor
    let scoreHigh: NSColor
    let scoreUnknown: NSColor
    let scoreText: NSColor
}

@MainActor
enum CandidatePaletteData {
    static let palettes: [String: CandidatePalette] = [
        "light": CandidatePalette(
            background: NSColor(srgbRed: 0.968627451, green: 0.968627451, blue: 0.972549020, alpha: 1),
            surface: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            text: NSColor(srgbRed: 0.125490196, green: 0.129411765, blue: 0.141176471, alpha: 1),
            secondaryText: NSColor(srgbRed: 0.325490196, green: 0.337254902, blue: 0.360784314, alpha: 1),
            border: NSColor(srgbRed: 0.450980392, green: 0.466666667, blue: 0.501960784, alpha: 1),
            selection: NSColor(srgbRed: 0.223529412, green: 0.250980392, blue: 0.294117647, alpha: 1),
            selectionText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            scoreLow: NSColor(srgbRed: 0.603921569, green: 0.274509804, blue: 0.000000000, alpha: 1),
            scoreHigh: NSColor(srgbRed: 0.192156863, green: 0.364705882, blue: 0.611764706, alpha: 1),
            scoreUnknown: NSColor(srgbRed: 0.356862745, green: 0.376470588, blue: 0.407843137, alpha: 1),
            scoreText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1)
        ),
        "dark": CandidatePalette(
            background: NSColor(srgbRed: 0.125490196, green: 0.129411765, blue: 0.141176471, alpha: 1),
            surface: NSColor(srgbRed: 0.160784314, green: 0.168627451, blue: 0.188235294, alpha: 1),
            text: NSColor(srgbRed: 0.952941176, green: 0.952941176, blue: 0.956862745, alpha: 1),
            secondaryText: NSColor(srgbRed: 0.764705882, green: 0.772549020, blue: 0.792156863, alpha: 1),
            border: NSColor(srgbRed: 0.568627451, green: 0.588235294, blue: 0.619607843, alpha: 1),
            selection: NSColor(srgbRed: 0.886274510, green: 0.898039216, blue: 0.917647059, alpha: 1),
            selectionText: NSColor(srgbRed: 0.125490196, green: 0.129411765, blue: 0.141176471, alpha: 1),
            scoreLow: NSColor(srgbRed: 0.603921569, green: 0.274509804, blue: 0.000000000, alpha: 1),
            scoreHigh: NSColor(srgbRed: 0.192156863, green: 0.364705882, blue: 0.611764706, alpha: 1),
            scoreUnknown: NSColor(srgbRed: 0.356862745, green: 0.376470588, blue: 0.407843137, alpha: 1),
            scoreText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1)
        ),
        "highContrastLight": CandidatePalette(
            background: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            surface: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            text: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1),
            secondaryText: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1),
            border: NSColor(srgbRed: 0.349019608, green: 0.349019608, blue: 0.349019608, alpha: 1),
            selection: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1),
            selectionText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            scoreLow: NSColor(srgbRed: 0.439215686, green: 0.188235294, blue: 0.000000000, alpha: 1),
            scoreHigh: NSColor(srgbRed: 0.000000000, green: 0.239215686, blue: 0.501960784, alpha: 1),
            scoreUnknown: NSColor(srgbRed: 0.270588235, green: 0.270588235, blue: 0.270588235, alpha: 1),
            scoreText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1)
        ),
        "highContrastDark": CandidatePalette(
            background: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1),
            surface: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1),
            text: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            secondaryText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            border: NSColor(srgbRed: 0.666666667, green: 0.666666667, blue: 0.666666667, alpha: 1),
            selection: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            selectionText: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1),
            scoreLow: NSColor(srgbRed: 0.996078431, green: 0.843137255, blue: 0.666666667, alpha: 1),
            scoreHigh: NSColor(srgbRed: 0.745098039, green: 0.858823529, blue: 1.000000000, alpha: 1),
            scoreUnknown: NSColor(srgbRed: 0.870588235, green: 0.870588235, blue: 0.870588235, alpha: 1),
            scoreText: NSColor(srgbRed: 0.000000000, green: 0.000000000, blue: 0.000000000, alpha: 1)
        )
    ]
}
