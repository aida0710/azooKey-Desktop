// User-facing strings are kept outside rendering and interaction code.
export const messages = {
    detail: '候補の詳細',
    detailKeys: '矢印キーで詳細を確認・PageUp / PageDownで詳細をスクロール',
    position: (position, total) => `変換候補 ${position} / ${total}`,
    openList: '一覧',
    closeList: '閉じる',
    previousPage: '前へ',
    nextPage: '次へ',
    activate: '実行',
    reading: reading => `読み ${reading}`,
    wordPosition: (position, total) => `語 ${position} / ${total}`,
    commit: text => `確定予定 ${text}`,
    remaining: reading => `残る読み ${reading}`,
};
