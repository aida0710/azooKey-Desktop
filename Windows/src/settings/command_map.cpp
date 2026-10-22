#include "command_map.h"

#include <utility>

namespace azookey::settings {

int CommandMap::Register(Handler handler) {
    int id = nextId_++;
    handlers_.emplace(id, std::move(handler));
    return id;
}

bool CommandMap::Dispatch(int id, unsigned notification) const {
    auto found = handlers_.find(id);
    if (found == handlers_.end()) return false;
    // A handler may register new controls, which can move the stored handler.
    Handler handler = found->second;
    handler(notification);
    return true;
}

}  // namespace azookey::settings
