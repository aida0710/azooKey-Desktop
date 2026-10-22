#include "list_view.h"

#include <commctrl.h>

#include <numeric>

namespace azookey::settings {

HWND CreateReportList(HWND parent, int id, const std::vector<std::wstring>& columnTitles) {
    HWND list = CreateWindowExW(WS_EX_CLIENTEDGE, WC_LISTVIEWW, L"",
                                WS_CHILD | WS_VISIBLE | WS_TABSTOP | LVS_REPORT | LVS_SINGLESEL | LVS_SHOWSELALWAYS, 0,
                                0, 0, 0, parent, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                                reinterpret_cast<HINSTANCE>(GetWindowLongPtrW(parent, GWLP_HINSTANCE)), nullptr);
    ListView_SetExtendedListViewStyle(list, LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER);
    for (size_t index = 0; index < columnTitles.size(); ++index) {
        LVCOLUMNW column{};
        column.mask = LVCF_TEXT | LVCF_WIDTH;
        column.pszText = const_cast<wchar_t*>(columnTitles[index].c_str());
        column.cx = 100;
        ListView_InsertColumn(list, static_cast<int>(index), &column);
    }
    return list;
}

void ResizeColumns(HWND list, const std::vector<int>& weights) {
    RECT client{};
    GetClientRect(list, &client);
    int total = std::accumulate(weights.begin(), weights.end(), 0);
    if (total <= 0) return;
    for (size_t index = 0; index < weights.size(); ++index) {
        ListView_SetColumnWidth(list, static_cast<int>(index), MulDiv(client.right, weights[index], total));
    }
}

void AppendRow(HWND list, const std::vector<std::wstring>& texts, LPARAM data) {
    LVITEMW item{};
    item.mask = LVIF_TEXT | LVIF_PARAM;
    item.iItem = ListView_GetItemCount(list);
    item.pszText = const_cast<wchar_t*>(texts.empty() ? L"" : texts[0].c_str());
    item.lParam = data;
    int row = ListView_InsertItem(list, &item);
    for (size_t column = 1; column < texts.size(); ++column) {
        ListView_SetItemText(list, row, static_cast<int>(column), const_cast<wchar_t*>(texts[column].c_str()));
    }
}

LPARAM SelectedRowData(HWND list) {
    int row = ListView_GetNextItem(list, -1, LVNI_SELECTED);
    if (row < 0) return -1;
    LVITEMW item{};
    item.mask = LVIF_PARAM;
    item.iItem = row;
    ListView_GetItem(list, &item);
    return item.lParam;
}

bool SelectRowWithData(HWND list, LPARAM data) {
    LVFINDINFOW find{};
    find.flags = LVFI_PARAM;
    find.lParam = data;
    int row = ListView_FindItem(list, -1, &find);
    if (row < 0) return false;
    ListView_SetItemState(list, row, LVIS_SELECTED | LVIS_FOCUSED, LVIS_SELECTED | LVIS_FOCUSED);
    ListView_EnsureVisible(list, row, FALSE);
    return true;
}

}  // namespace azookey::settings
