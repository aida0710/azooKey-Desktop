#include "json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace azookey::json {
namespace {

const Value& NullValue() {
    static const Value null;
    return null;
}

const std::string& EmptyString() {
    static const std::string empty;
    return empty;
}

void AppendUtf8(uint32_t scalar, std::string* out) {
    if (scalar < 0x80) {
        out->push_back(static_cast<char>(scalar));
    } else if (scalar < 0x800) {
        out->push_back(static_cast<char>(0xC0 | (scalar >> 6)));
        out->push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
    } else if (scalar < 0x10000) {
        out->push_back(static_cast<char>(0xE0 | (scalar >> 12)));
        out->push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3F)));
        out->push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
    } else {
        out->push_back(static_cast<char>(0xF0 | (scalar >> 18)));
        out->push_back(static_cast<char>(0x80 | ((scalar >> 12) & 0x3F)));
        out->push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3F)));
        out->push_back(static_cast<char>(0x80 | (scalar & 0x3F)));
    }
}

class Parser {
public:
    explicit Parser(const std::string& text) : text_(text) {}

    std::optional<Value> ParseDocument() {
        auto value = ParseValue(0);
        SkipWhitespace();
        if (!value || position_ != text_.size()) return std::nullopt;
        return value;
    }

private:
    // Deeply nested input is rejected rather than risking stack exhaustion.
    static constexpr int kMaximumDepth = 64;

    void SkipWhitespace() {
        while (position_ < text_.size()) {
            char c = text_[position_];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
            ++position_;
        }
    }

    bool Consume(const char* literal) {
        size_t length = std::char_traits<char>::length(literal);
        if (text_.compare(position_, length, literal) != 0) return false;
        position_ += length;
        return true;
    }

    std::optional<Value> ParseValue(int depth) {
        if (depth > kMaximumDepth) return std::nullopt;
        SkipWhitespace();
        if (position_ >= text_.size()) return std::nullopt;
        char c = text_[position_];
        if (c == '{') return ParseObject(depth);
        if (c == '[') return ParseArray(depth);
        if (c == '"') {
            auto text = ParseString();
            if (!text) return std::nullopt;
            return Value::MakeString(std::move(*text));
        }
        if (Consume("true")) return Value::MakeBoolean(true);
        if (Consume("false")) return Value::MakeBoolean(false);
        if (Consume("null")) return Value();
        return ParseNumber();
    }

    std::optional<Value> ParseNumber() {
        size_t start = position_;
        if (position_ < text_.size() && text_[position_] == '-') ++position_;
        bool digits = false;
        while (position_ < text_.size()) {
            char c = text_[position_];
            if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                digits = digits || (c >= '0' && c <= '9');
                ++position_;
            } else {
                break;
            }
        }
        if (!digits) return std::nullopt;
        std::string token = text_.substr(start, position_ - start);
        char* end = nullptr;
        double number = std::strtod(token.c_str(), &end);
        if (end == nullptr || *end != '\0') return std::nullopt;
        return Value::MakeNumber(number);
    }

    std::optional<uint32_t> ParseHex4() {
        if (position_ + 4 > text_.size()) return std::nullopt;
        uint32_t value = 0;
        for (int i = 0; i < 4; ++i) {
            char c = text_[position_++];
            value <<= 4;
            if (c >= '0' && c <= '9') value |= c - '0';
            else if (c >= 'a' && c <= 'f') value |= c - 'a' + 10;
            else if (c >= 'A' && c <= 'F') value |= c - 'A' + 10;
            else return std::nullopt;
        }
        return value;
    }

    std::optional<std::string> ParseString() {
        ++position_;  // opening quote
        std::string out;
        while (position_ < text_.size()) {
            char c = text_[position_++];
            if (c == '"') return out;
            if (static_cast<unsigned char>(c) < 0x20) return std::nullopt;
            if (c != '\\') {
                out.push_back(c);
                continue;
            }
            if (position_ >= text_.size()) return std::nullopt;
            char escape = text_[position_++];
            switch (escape) {
            case '"': out.push_back('"'); break;
            case '\\': out.push_back('\\'); break;
            case '/': out.push_back('/'); break;
            case 'b': out.push_back('\b'); break;
            case 'f': out.push_back('\f'); break;
            case 'n': out.push_back('\n'); break;
            case 'r': out.push_back('\r'); break;
            case 't': out.push_back('\t'); break;
            case 'u': {
                auto unit = ParseHex4();
                if (!unit) return std::nullopt;
                uint32_t scalar = *unit;
                if (scalar >= 0xD800 && scalar <= 0xDBFF) {
                    if (!Consume("\\u")) return std::nullopt;
                    auto low = ParseHex4();
                    if (!low || *low < 0xDC00 || *low > 0xDFFF) return std::nullopt;
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (*low - 0xDC00);
                } else if (scalar >= 0xDC00 && scalar <= 0xDFFF) {
                    return std::nullopt;
                }
                AppendUtf8(scalar, &out);
                break;
            }
            default:
                return std::nullopt;
            }
        }
        return std::nullopt;
    }

    std::optional<Value> ParseArray(int depth) {
        ++position_;
        std::vector<Value> items;
        SkipWhitespace();
        if (position_ < text_.size() && text_[position_] == ']') {
            ++position_;
            return Value::MakeArray(std::move(items));
        }
        for (;;) {
            auto item = ParseValue(depth + 1);
            if (!item) return std::nullopt;
            items.push_back(std::move(*item));
            SkipWhitespace();
            if (position_ >= text_.size()) return std::nullopt;
            char c = text_[position_++];
            if (c == ']') return Value::MakeArray(std::move(items));
            if (c != ',') return std::nullopt;
        }
    }

    std::optional<Value> ParseObject(int depth) {
        ++position_;
        std::map<std::string, Value> members;
        SkipWhitespace();
        if (position_ < text_.size() && text_[position_] == '}') {
            ++position_;
            return Value::MakeObject(std::move(members));
        }
        for (;;) {
            SkipWhitespace();
            if (position_ >= text_.size() || text_[position_] != '"') return std::nullopt;
            auto name = ParseString();
            if (!name) return std::nullopt;
            SkipWhitespace();
            if (position_ >= text_.size() || text_[position_++] != ':') return std::nullopt;
            auto value = ParseValue(depth + 1);
            if (!value) return std::nullopt;
            members[std::move(*name)] = std::move(*value);
            SkipWhitespace();
            if (position_ >= text_.size()) return std::nullopt;
            char c = text_[position_++];
            if (c == '}') return Value::MakeObject(std::move(members));
            if (c != ',') return std::nullopt;
        }
    }

    const std::string& text_;
    size_t position_ = 0;
};

void SerializeTo(const Value& value, std::string* out) {
    switch (value.kind()) {
    case Value::Kind::Null: out->append("null"); break;
    case Value::Kind::Boolean: out->append(value.AsBoolean() ? "true" : "false"); break;
    case Value::Kind::Number: {
        double number = value.AsNumber();
        char buffer[32];
        if (std::isfinite(number) && number == std::floor(number) && std::fabs(number) < 9.0e15) {
            std::snprintf(buffer, sizeof(buffer), "%lld", static_cast<long long>(number));
        } else if (std::isfinite(number)) {
            std::snprintf(buffer, sizeof(buffer), "%.17g", number);
        } else {
            std::snprintf(buffer, sizeof(buffer), "null");
        }
        out->append(buffer);
        break;
    }
    case Value::Kind::String: out->append(Quote(value.AsString())); break;
    case Value::Kind::Array: {
        out->push_back('[');
        bool first = true;
        for (const auto& item : value.AsArray()) {
            if (!first) out->push_back(',');
            first = false;
            SerializeTo(item, out);
        }
        out->push_back(']');
        break;
    }
    case Value::Kind::Object: {
        out->push_back('{');
        bool first = true;
        for (const auto& [name, member] : value.AsObject()) {
            if (!first) out->push_back(',');
            first = false;
            out->append(Quote(name));
            out->push_back(':');
            SerializeTo(member, out);
        }
        out->push_back('}');
        break;
    }
    }
}

}  // namespace

Value Value::MakeBoolean(bool value) {
    Value result;
    result.kind_ = Kind::Boolean;
    result.boolean_ = value;
    return result;
}

Value Value::MakeNumber(double value) {
    Value result;
    result.kind_ = Kind::Number;
    result.number_ = value;
    return result;
}

Value Value::MakeString(std::string value) {
    Value result;
    result.kind_ = Kind::String;
    result.string_ = std::move(value);
    return result;
}

Value Value::MakeArray(std::vector<Value> items) {
    Value result;
    result.kind_ = Kind::Array;
    result.array_ = std::move(items);
    return result;
}

Value Value::MakeObject(std::map<std::string, Value> members) {
    Value result;
    result.kind_ = Kind::Object;
    result.object_ = std::move(members);
    return result;
}

bool Value::AsBoolean(bool fallback) const { return kind_ == Kind::Boolean ? boolean_ : fallback; }
double Value::AsNumber(double fallback) const { return kind_ == Kind::Number ? number_ : fallback; }

int64_t Value::AsInteger(int64_t fallback) const {
    if (kind_ != Kind::Number || !std::isfinite(number_)) return fallback;
    return static_cast<int64_t>(number_);
}

const std::string& Value::AsString() const { return kind_ == Kind::String ? string_ : EmptyString(); }

const std::vector<Value>& Value::AsArray() const {
    static const std::vector<Value> empty;
    return kind_ == Kind::Array ? array_ : empty;
}

const std::map<std::string, Value>& Value::AsObject() const {
    static const std::map<std::string, Value> empty;
    return kind_ == Kind::Object ? object_ : empty;
}

const Value& Value::operator[](const std::string& name) const {
    if (kind_ != Kind::Object) return NullValue();
    auto found = object_.find(name);
    return found == object_.end() ? NullValue() : found->second;
}

bool Value::Has(const std::string& name) const {
    return kind_ == Kind::Object && object_.count(name) != 0;
}

std::optional<Value> Parse(const std::string& text) {
    return Parser(text).ParseDocument();
}

std::string Serialize(const Value& value) {
    std::string out;
    SerializeTo(value, &out);
    return out;
}

std::string Quote(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 2);
    out.push_back('"');
    for (unsigned char c : text) {
        switch (c) {
        case '"': out.append("\\\""); break;
        case '\\': out.append("\\\\"); break;
        case '\n': out.append("\\n"); break;
        case '\r': out.append("\\r"); break;
        case '\t': out.append("\\t"); break;
        default:
            if (c < 0x20 || c == 0x7F) {
                // Control characters, including Ctrl+Z, never reach the line protocol raw.
                char buffer[8];
                std::snprintf(buffer, sizeof(buffer), "\\u%04x", c);
                out.append(buffer);
            } else {
                out.push_back(static_cast<char>(c));
            }
        }
    }
    out.push_back('"');
    return out;
}

}  // namespace azookey::json
