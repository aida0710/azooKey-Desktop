import Core
import SwiftUI

@MainActor
final class UserDictionaryImportOptions: ObservableObject {
    @Published var format = UserDictionaryExchange.Format.json
    @Published var encoding = UserDictionaryExchange.TextEncoding.automatic

    var selected: UserDictionaryFileExchangeService.ImportOptions {
        .init(format: format, encoding: encoding)
    }
}

@MainActor
struct UserDictionaryImportOptionsView: View {
    // Leave room for encoding names and the supported-format notice in the native panel.
    private static let accessoryWidth: CGFloat = 440
    @ObservedObject var options: UserDictionaryImportOptions

    var body: some View {
        Form {
            Picker(UserDictionaryMessages.text("importFormat"), selection: $options.format) {
                ForEach(UserDictionaryExchange.Format.allCases, id: \.self) { format in
                    Text(UserDictionaryMessages.text("importFormat." + format.rawValue)).tag(format)
                }
            }
            Picker(UserDictionaryMessages.text("importEncoding"), selection: $options.encoding) {
                ForEach(UserDictionaryExchange.TextEncoding.allCases, id: \.self) { encoding in
                    Text(UserDictionaryMessages.text("importEncoding." + encoding.rawValue)).tag(encoding)
                }
            }
            Text(UserDictionaryMessages.text("importFormatHelp"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: Self.accessoryWidth)
    }
}
