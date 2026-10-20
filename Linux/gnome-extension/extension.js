import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const NAME = 'org.azookey.Tree';
const PATH = '/org/azookey/Tree';

export default class AzooKeyTreeExtension extends Extension {
    enable() {
        this._popup = new St.ScrollView({
            reactive: true, can_focus: false,
            hscrollbar_policy: St.PolicyType.AUTOMATIC,
            vscrollbar_policy: St.PolicyType.NEVER,
            style: 'background-color: transparent; border: none; box-shadow: none;',
        });
        this._content = new St.BoxLayout({vertical: true});
        this._canvas = new St.Widget({layout_manager: new Clutter.FixedLayout(),
            style: 'background-color: #202124; border-radius: 6px;'});
        this._content.add_child(this._canvas);
        this._popup.set_child(this._content);
        Main.layoutManager.addTopChrome(this._popup);
        this._popup.hide();
        this._subscription = Gio.DBus.session.signal_subscribe(NAME, NAME, null, PATH, null,
            Gio.DBusSignalFlags.NONE, (_connection, _sender, _path, _interface, signal, parameters) => {
                if (signal === 'Hide') this._popup.hide();
                if (signal === 'Update') {
                    try { this._render(JSON.parse(parameters.deepUnpack()[0])); }
                    catch (error) {
                        console.error('azooKey candidate rendering failed', error);
                        this._popup.hide();
                        this._call('SetRenderer', new GLib.Variant('(b)', [false]));
                    }
                }
            });
        this._watch = Gio.bus_watch_name(Gio.BusType.SESSION, NAME, Gio.BusNameWatcherFlags.NONE,
            () => this._call('SetRenderer', new GLib.Variant('(b)', [true])),
            () => this._popup.hide());
    }

    _call(method, parameters) {
        Gio.DBus.session.call(NAME, PATH, NAME, method, parameters, null, Gio.DBusCallFlags.NONE,
            2000, null, (connection, result) => {
                try { connection.call_finish(result); } catch { /* Engine may be shutting down. */ }
            });
    }

    _render(data) {
        const nodes = data.nodes ?? [];
        if (!nodes.length) { this._popup.hide(); return; }
        this._canvas.destroy_all_children();
        const byId = new Map(nodes.map(node => [node.id, node]));
        const columns = data.columns ?? [];
        if (!columns.length) { this._popup.hide(); return; }
        const frames = new Map();
        const documentWidths = data.wordGeometry?.widths ?? [];
        const aligned = documentWidths.length === columns.length && documentWidths.every(w => Number.isFinite(w) && w >= 6);
        const fontSize = aligned ? Math.min(12, data.wordGeometry.fontSize ?? 12) : 12;
        const rowHeight = 24, rowPitch = rowHeight + (data.showCandidateIndex && aligned ? 30 : 18);
        const scoreColor = score => Number.isFinite(score) && score < 75 ? '#d4630f' : '#4073cc';
        let nextX = 12;
        for (const [depth, column] of columns.entries()) {
            const measure = new St.Label({text: byId.get(column[0]).text, style: 'font-size: 13px;'});
            const columnWidth = aligned ? documentWidths[depth] : Math.max(24, Math.min(160, measure.get_preferred_width(-1)[1] + 12));
            measure.destroy();
            column.forEach((id, row) => frames.set(id, {x: nextX, y: 6 + row * rowPitch, width: columnWidth, height: rowHeight}));
            nextX += columnWidth + (aligned ? 0 : (data.showCandidateIndex ? 22 : 12));
        }
        const width = Math.max(60, nextX);
        const height = Math.max(32, Math.max(...columns.map(column => column.length)) * rowPitch + 6);
        this._canvas.set_size(width, height);
        const selected = new Set(data.selectedPath ?? []);
        const edges = columns.flat().map(id => {
            const node = byId.get(id);
            const parent = frames.get(node.parent), target = frames.get(id);
            return {x1: parent ? parent.x + parent.width : 4, y1: parent ? parent.y + rowHeight / 2 : 6 + rowHeight / 2,
                x2: target.x, y2: target.y + rowHeight / 2, active: selected.has(id),
                orange: Number.isFinite(node.relativeScore) && node.relativeScore < 75};
        });
        // A long phrase can have > 300 candidates and exceed the GPU's maximum
        // texture height. St.DrawingArea uses a texture; draw bounded tiles so
        // scrolling remains valid on both virtual and physical GPUs.
        for (let top = 0; top < height; top += 512) {
            for (let left = 0; left < width; left += 512) {
                const tileWidth = Math.min(512, width - left), tileHeight = Math.min(512, height - top);
                const visibleEdges = edges.filter(edge => edge.x2 >= left && edge.x1 <= left + tileWidth &&
                    Math.max(edge.y1, edge.y2) + 3 >= top && Math.min(edge.y1, edge.y2) - 3 <= top + tileHeight);
                const lines = new St.DrawingArea({width: tileWidth, height: tileHeight});
                lines.set_position(left, top);
                lines.connect('repaint', area => {
                    const cr = area.get_context();
                    cr.setSourceRGBA(0, 0, 0, 0);
                    cr.paint();
                    cr.translate(-left, -top);
                    for (const edge of visibleEdges) {
                        const middle = (edge.x1 + edge.x2) / 2;
                        if (edge.active && edge.orange) cr.setSourceRGBA(0.83, 0.39, 0.06, 1);
                        else if (edge.active) cr.setSourceRGBA(0.25, 0.45, 0.8, 1);
                        else cr.setSourceRGBA(0.5, 0.5, 0.55, 0.55);
                        cr.setLineWidth(edge.active ? 2 : 0.75);
                        cr.moveTo(edge.x1, edge.y1);
                        cr.curveTo(middle, edge.y1, middle, edge.y2, edge.x2, edge.y2);
                        cr.stroke();
                    }
                    if (left === 0 && top === 0) {
                        cr.setSourceRGBA(0.5, 0.5, 0.55, 1);
                        cr.arc(4, 18, 3, 0, Math.PI * 2);
                        cr.fill();
                    }
                    cr.$dispose();
                });
                this._canvas.add_child(lines);
                lines.queue_repaint();
            }
        }
        const button = (operation, index, label, x, y, w, h, active, focused, accessibleName, score) => {
            const compactBadge = operation === 'select' && aligned;
            const widget = new St.Button({can_focus: false, reactive: true, accessible_name: accessibleName,
                style: `color: ${active ? '#ffffff' : '#eeeeef'}; background-color: ${active ? scoreColor(score) : '#24252b'}; border: none; border-bottom: ${compactBadge ? '0' : (focused ? '2px solid #ffffff' : '2px solid transparent')}; border-radius: 4px; padding: ${compactBadge ? 0 : 2}px; font-size: 12px;`});
            const captions = new St.BoxLayout({vertical: true, y_align: Clutter.ActorAlign.CENTER});
            const caption = new St.Label({text: label, x_align: aligned ? Clutter.ActorAlign.START : Clutter.ActorAlign.CENTER});
            let size = operation === 'select' ? (aligned ? 7 : 11) : fontSize;
            for (let attempt = 0; attempt < 12; attempt++) {
                caption.set_style(`font-size: ${size}px;`);
                const measured = caption.get_preferred_width(-1)[1];
                if (measured <= w - 4 || size <= 8) break;
                size = Math.max(8, Math.min(size - 0.25, size * (w - 4) / measured));
            }
            caption.set_width(Math.max(1, w - 4));
            captions.add_child(caption);
            widget.set_child(captions);
            widget.set_position(x, y);
            widget.set_size(w, h);
            widget.connect('button-press-event', (_actor, event) => {
                if (event.get_button() !== 1) return Clutter.EVENT_PROPAGATE;
                const submit = true;
                this._call('Select', new GLib.Variant('(sibis)', [operation, index, submit, data.generation, data.contextId]));
                return Clutter.EVENT_STOP;
            });
            this._canvas.add_child(widget);
        };
        for (const [id, frame] of frames) {
            const node = byId.get(id);
            const score = node.relativeScore;
            const detail = Number.isFinite(score)
                ? `相対スコア ${score}（取得候補内の評価。正解の確率ではありません）` : '比較可能なスコアなし';
            button('node', id, node.text, frame.x, frame.y, frame.width, frame.height,
                selected.has(id), id === data.focusedNode, `${node.text} ${node.reading} ${detail}`, score);
            const scoreText = Number.isFinite(score) ? String(score) : '—';
            const scoreLabel = new St.Label({text: scoreText, accessible_name: detail,
                style: `color: #a9a9b0; font-size: ${Math.min(9, frame.width / (scoreText.length * 0.65))}px;`,
                x_align: Clutter.ActorAlign.CENTER});
            scoreLabel.set_position(frame.x, frame.y + frame.height);
            scoreLabel.set_size(frame.width, 12);
            this._canvas.add_child(scoreLabel);
            const index = node.terminals.includes(data.selection) ? data.selection : node.terminals[0];
            if (data.showCandidateIndex && index !== undefined) {
                const number = index - (data.pageStart ?? 0) + 1;
                if (number >= 1 && number <= 9) {
                    button('select', index, String(number), aligned ? frame.x + frame.width - 12 : frame.x + frame.width + 1,
                        aligned ? frame.y + frame.height + 12 : frame.y + 2, aligned ? 12 : 20, aligned ? 10 : 20,
                        index === data.selection, false, `候補 ${index + 1} を確定`);
                }
            }
        }
        let [x, y, , cursorHeight] = data.location ?? [0, 0, 0, 0];
        if (aligned) x -= 12;
        const monitorIndex = Main.layoutManager.monitors.findIndex(m => x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height);
        const index = monitorIndex >= 0 ? monitorIndex : Main.layoutManager.primaryIndex;
        const bounds = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(index);
        if (aligned && (x < bounds.x || x + width > bounds.x + bounds.width)) {
            this._render({...data, wordGeometry: null});
            return;
        }
        // The popup follows the compact content; there is no full-window backdrop.
        const popupWidth = Math.min(width, aligned ? width : 760, bounds.width), popupHeight = Math.min(height, bounds.height);
        this._popup.set_size(popupWidth, popupHeight);
        x = Math.max(bounds.x, Math.min(x, bounds.x + bounds.width - popupWidth));
        y = y + cursorHeight + popupHeight <= bounds.y + bounds.height ? y + cursorHeight : y - popupHeight;
        this._popup.set_position(x, Math.max(bounds.y, Math.min(y, bounds.y + bounds.height - popupHeight)));
        this._popup.show();
        const focus = frames.get(data.focusedNode);
        const focusKey = `${data.contextId}:${data.generation}:${data.selection}:${data.focusedNode}`;
        if (focus && focusKey !== this._focusKey) {
            this._focusKey = focusKey;
            if (this._scrollIdle) GLib.source_remove(this._scrollIdle);
            this._scrollIdle = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                this._scrollIdle = 0;
                const reveal = (adjustment, start, end) => {
                    let value = adjustment.value;
                    if (start < value) value = start;
                    else if (end > value + adjustment.page_size) value = end - adjustment.page_size;
                    adjustment.value = Math.max(adjustment.lower,
                        Math.min(value, adjustment.upper - adjustment.page_size));
                };
                reveal(this._popup.get_hadjustment(), Math.max(0, focus.x - 8), focus.x + focus.width + 22);
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    disable() {
        this._call('SetRenderer', new GLib.Variant('(b)', [false]));
        if (this._watch) Gio.bus_unwatch_name(this._watch);
        if (this._subscription) Gio.DBus.session.signal_unsubscribe(this._subscription);
        if (this._scrollIdle) GLib.source_remove(this._scrollIdle);
        this._scrollIdle = 0;
        this._focusKey = null;
        this._popup?.destroy();
        this._popup = null;
    }
}
