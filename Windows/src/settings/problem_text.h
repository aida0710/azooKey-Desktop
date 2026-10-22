// The text the screen shows for a problem Core reported. Core names the
// setting in "field" by its key ("inferenceLimit", "transformShortcut.key");
// the user knows the setting by its label, so known keys become labels.
#pragma once

#include <string>

#include "../shared/message_catalog_data.h"
#include "settings_protocol.h"
#include "settings_schema.h"

namespace azookey::settings {

// `schema` may be null before the definition has arrived.
std::wstring ProblemText(const Problem& problem, messages::Language language, const Schema* schema);

}  // namespace azookey::settings
