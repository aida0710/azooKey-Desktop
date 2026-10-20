"""User-facing text for the local, non-focusing reconversion prompt."""
MESSAGES = {
    "undo_menu": "直前の確定を取り消す（Ctrl+Shift+Backspace）",
    "selection_menu": "選択した文字を再変換（Ctrl+Shift+R）",
    "reading_input": "読みを入力: {reading}　Enterで再変換 / Escで取消",
    "private_input": "保護された入力では再変換できません",
    "replacement_unavailable": "この入力先では範囲の置換を確認できません",
    "invalid_context": "選択範囲を確認できません",
    "no_recent_commit": "取り消せる直前の確定がありません",
    "changed_context": "文字や入力位置が変わったため再変換を中止しました",
    "no_selection": "再変換する文字を選択してください",
    "reading_required": "再変換する文字の読みを入力してください",
    "stale_request": "再変換の操作が無効になりました",
    "composition_active": "入力中の文字を確定してから再変換してください",
    "whole_selection_required": "選択範囲全体の候補を選んでください",
}


def message(key, **values):
    return MESSAGES.get(key, MESSAGES["replacement_unavailable"]).format(**values)
