// Chooses the candidate palette that matches the desktop: light or dark apps
// theme, and the high-contrast themes (which always win).
#pragma once

#include "candidate_palette_data.h"

namespace azookey::tsf {

CandidateAppearance CurrentCandidateAppearance();
const CandidatePalette& PaletteFor(CandidateAppearance appearance);
bool IsHighContrast(CandidateAppearance appearance);

}  // namespace azookey::tsf
