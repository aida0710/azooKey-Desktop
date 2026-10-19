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
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            style: 'background-color: #f8f8fb; border: 1px solid #b7bfd1; border-radius: 10px;',
        });
        this._content = new St.BoxLayout({vertical: true});
        this._canvas = new St.Widget({layout_manager: new Clutter.FixedLayout()});
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
        const rows = new Map(), terminals = new Map();
        let nextRow = 0;
        const visit = node => {
            const first = nextRow;
            for (const index of node.terminals) terminals.set(index, nextRow++);
            for (const child of node.children) visit(byId.get(child));
            rows.set(node.id, (first + Math.max(first, nextRow - 1)) / 2);
        };
        nodes.filter(node => node.parent === undefined || node.parent === null).forEach(visit);
        const width = (Math.max(...nodes.map(node => node.depth)) + 1) * 210 + 16;
        const height = Math.max(80, nextRow * 64 + 32);
        this._canvas.set_size(width, height);
        const selected = new Set(data.selectedPath ?? []);
        const edges = nodes.flatMap(node => {
            const parent = byId.get(node.parent);
            if (!parent) return [];
            return [{x1: 166 + parent.depth * 210, y1: 40 + rows.get(parent.id) * 64,
                x2: 16 + node.depth * 210, y2: 40 + rows.get(node.id) * 64,
                active: selected.has(node.id)}];
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
                    cr.setSourceRGBA(0.973, 0.973, 0.984, 1);
                    cr.paint();
                    cr.translate(-left, -top);
                    for (const edge of visibleEdges) {
                        const middle = (edge.x1 + edge.x2) / 2;
                        if (edge.active) cr.setSourceRGBA(0.18, 0.38, 0.85, 1);
                        else cr.setSourceRGBA(0.65, 0.68, 0.75, 1);
                        cr.setLineWidth(edge.active ? 2.5 : 1);
                        cr.moveTo(edge.x1, edge.y1);
                        cr.curveTo(middle, edge.y1, middle, edge.y2, edge.x2, edge.y2);
                        cr.stroke();
                    }
                    cr.$dispose();
                });
                this._canvas.add_child(lines);
                lines.queue_repaint();
            }
        }
        const button = (operation, index, label, x, y, w, h, active, focused, accessibleName) => {
            const widget = new St.Button({can_focus: false, reactive: true, accessible_name: accessibleName,
                style: `color: #19202f; background-color: ${active ? '#d8e7ff' : '#ffffff'}; border: ${focused ? '2px solid #3366cc' : '1px solid #cbd0db'}; border-radius: 7px; padding: 3px; font-size: 15px;`});
            const captions = new St.BoxLayout({vertical: true, y_align: Clutter.ActorAlign.CENTER});
            label.split('\n').forEach((text, line) => captions.add_child(new St.Label({
                text, x_align: Clutter.ActorAlign.CENTER,
                style: line ? 'font-size: 10px; color: #596579;' : 'font-size: 15px;',
            })));
            widget.set_child(captions);
            widget.set_position(x, y);
            widget.set_size(w, h);
            widget.connect('button-press-event', (_actor, event) => {
                if (event.get_button() !== 1) return Clutter.EVENT_PROPAGATE;
                const submit = operation === 'select' || event.get_click_count() > 1;
                this._call('Select', new GLib.Variant('(sibis)', [operation, index, submit, data.generation, data.contextId]));
                return Clutter.EVENT_STOP;
            });
            this._canvas.add_child(widget);
        };
        for (const node of nodes) {
            const x = 16 + node.depth * 210;
            button('node', node.id, node.reading ? `${node.text}\n${node.reading}` : node.text,
                x, 16 + rows.get(node.id) * 64, 150, 48, selected.has(node.id), node.id === data.focusedNode,
                `${node.text} ${node.reading}`);
            for (const index of node.terminals) {
                const number = index - (data.pageStart ?? 0) + 1;
                button('select', index, number >= 1 && number <= 9 ? String(number) : '↵', x + 158, 26 + terminals.get(index) * 64, 30, 28,
                    index === data.selection, false, `候補 ${index + 1} を確定`);
            }
        }
        let [x, y, , cursorHeight] = data.location ?? [0, 0, 0, 0];
        const monitorIndex = Main.layoutManager.monitors.findIndex(m => x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height);
        const index = monitorIndex >= 0 ? monitorIndex : Main.layoutManager.primaryIndex;
        const bounds = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(index);
        // Reserve room for borders and a vertical scrollbar; otherwise even a
        // one-column tree gets an unnecessary horizontal scrollbar.
        const popupWidth = Math.min(width + 24, 760, bounds.width), popupHeight = Math.min(height + 8, 420, bounds.height);
        this._popup.set_size(popupWidth, popupHeight);
        x = Math.max(bounds.x, Math.min(x, bounds.x + bounds.width - popupWidth));
        y = y + cursorHeight + popupHeight <= bounds.y + bounds.height ? y + cursorHeight : y - popupHeight;
        this._popup.set_position(x, Math.max(bounds.y, Math.min(y, bounds.y + bounds.height - popupHeight)));
        this._popup.show();
        const focus = byId.get(data.focusedNode);
        const focusKey = `${data.contextId}:${data.generation}:${data.focusedNode}`;
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
                reveal(this._popup.get_hadjustment(), focus.depth * 210, focus.depth * 210 + 204);
                reveal(this._popup.get_vadjustment(), rows.get(focus.id) * 64, rows.get(focus.id) * 64 + 72);
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
