// A small JSON value type for the bridge protocol. The bridge only exchanges
// objects of strings, numbers, booleans and arrays, so this covers exactly that
// grammar (RFC 8259) without pulling a third-party library into the IME DLL.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace azookey::json {

class Value {
public:
    enum class Kind { Null, Boolean, Number, String, Array, Object };

    Value() = default;
    static Value MakeBoolean(bool value);
    static Value MakeNumber(double value);
    static Value MakeString(std::string value);
    static Value MakeArray(std::vector<Value> items);
    static Value MakeObject(std::map<std::string, Value> members);

    Kind kind() const { return kind_; }
    bool IsNull() const { return kind_ == Kind::Null; }

    bool AsBoolean(bool fallback = false) const;
    double AsNumber(double fallback = 0) const;
    int64_t AsInteger(int64_t fallback = 0) const;
    const std::string& AsString() const;
    const std::vector<Value>& AsArray() const;
    const std::map<std::string, Value>& AsObject() const;

    // Missing members read as null so callers can chain lookups.
    const Value& operator[](const std::string& name) const;
    bool Has(const std::string& name) const;

private:
    Kind kind_ = Kind::Null;
    bool boolean_ = false;
    double number_ = 0;
    std::string string_;
    std::vector<Value> array_;
    std::map<std::string, Value> object_;
};

// Returns nullopt for malformed input instead of throwing; a broken line from
// the converter must never take down the application hosting the IME.
std::optional<Value> Parse(const std::string& text);

std::string Serialize(const Value& value);

// Escapes a UTF-8 string as a JSON string literal including the quotes.
std::string Quote(const std::string& text);

}  // namespace azookey::json
