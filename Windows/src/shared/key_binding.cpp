#include "key_binding.h"

namespace azookey::keys {

bool KeyBinding::Matches(const CoreKeyEvent& event) const {
    if (event.modifierFlags != modifiers) return false;
    if (keyCode) return event.keyCode == *keyCode;
    auto unmodified = event.CharactersIgnoringModifiers();
    return key && unmodified && *unmodified == *key;
}

const KeyBinding* FindBinding(const CoreKeyEvent& event, const std::vector<KeyBinding>& bindings) {
    for (const auto& binding : bindings) {
        if (binding.Matches(event)) return &binding;
    }
    return nullptr;
}

}  // namespace azookey::keys
