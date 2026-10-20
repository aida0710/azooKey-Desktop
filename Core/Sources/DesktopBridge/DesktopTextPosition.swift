/// IBusはUnicode scalar単位でカーソル位置を受け取る。
func unicodeScalarOffset(in text: String, utf16Offset: Int) -> Int {
    let limit = min(max(utf16Offset, 0), text.utf16.count)
    var consumedUTF16Count = 0
    var scalarCount = 0
    for scalar in text.unicodeScalars {
        let scalarLength = scalar.utf16.count
        guard consumedUTF16Count + scalarLength <= limit else {
            // 不正なUTF-16位置でも、サロゲートペアの途中から置換文字を作らない。
            break
        }
        consumedUTF16Count += scalarLength
        scalarCount += 1
    }
    return scalarCount
}
