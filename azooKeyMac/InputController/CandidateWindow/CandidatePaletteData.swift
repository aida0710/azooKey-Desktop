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
            background: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1),
            surface: NSColor(srgbRed: 0.964705882, green: 0.960784314, blue: 0.976470588, alpha: 1),
            text: NSColor(srgbRed: 0.141176471, green: 0.141176471, blue: 0.200000000, alpha: 1),
            secondaryText: NSColor(srgbRed: 0.384313725, green: 0.380392157, blue: 0.443137255, alpha: 1),
            border: NSColor(srgbRed: 0.505882353, green: 0.474509804, blue: 0.560784314, alpha: 1),
            selection: NSColor(srgbRed: 0.933333333, green: 0.909803922, blue: 1.000000000, alpha: 1),
            selectionText: NSColor(srgbRed: 0.207843137, green: 0.149019608, blue: 0.368627451, alpha: 1),
            scoreLow: NSColor(srgbRed: 0.603921569, green: 0.274509804, blue: 0.000000000, alpha: 1),
            scoreHigh: NSColor(srgbRed: 0.192156863, green: 0.364705882, blue: 0.611764706, alpha: 1),
            scoreUnknown: NSColor(srgbRed: 0.356862745, green: 0.376470588, blue: 0.407843137, alpha: 1),
            scoreText: NSColor(srgbRed: 1.000000000, green: 1.000000000, blue: 1.000000000, alpha: 1)
        ),
        "dark": CandidatePalette(
            background: NSColor(srgbRed: 0.125490196, green: 0.129411765, blue: 0.149019608, alpha: 1),
            surface: NSColor(srgbRed: 0.164705882, green: 0.164705882, blue: 0.203921569, alpha: 1),
            text: NSColor(srgbRed: 0.952941176, green: 0.945098039, blue: 0.976470588, alpha: 1),
            secondaryText: NSColor(srgbRed: 0.721568627, green: 0.713725490, blue: 0.784313725, alpha: 1),
            border: NSColor(srgbRed: 0.596078431, green: 0.568627451, blue: 0.662745098, alpha: 1),
            selection: NSColor(srgbRed: 0.235294118, green: 0.188235294, blue: 0.356862745, alpha: 1),
            selectionText: NSColor(srgbRed: 0.952941176, green: 0.945098039, blue: 0.976470588, alpha: 1),
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
