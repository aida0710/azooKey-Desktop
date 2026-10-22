// Report-style list views on these screens: titled columns sized by weight,
// one row per item with the item's number kept as the row's data.
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace azookey::settings {

// Creates a report list view with full-row selection that always shows the selection.
HWND CreateReportList(HWND parent, int id, const std::vector<std::wstring>& columnTitles);
// Gives each column a share of the list's width proportional to its weight.
void ResizeColumns(HWND list, const std::vector<int>& weights);
void AppendRow(HWND list, const std::vector<std::wstring>& texts, LPARAM data);
// The data of the selected row, or -1.
LPARAM SelectedRowData(HWND list);
// Selects and focuses the row whose data is `data`, scrolling it into view.
bool SelectRowWithData(HWND list, LPARAM data);

}  // namespace azookey::settings
