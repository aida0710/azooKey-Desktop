import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {CandidateDetail} from './candidateDetail.js';
import {messages} from './candidateMessages.js';
import {candidatePlacement} from './candidatePlacement.js';
import {ShellCursor} from './shellCursor.js';
import {LayoutDiagnostics} from './layoutDiagnostics.js';
import {CandidateNavigation} from './candidateNavigation.js';

const NAME = 'org.azookey.Tree';
const PATH = '/org/azookey/Tree';

export default class AzooKeyTreeExtension extends Extension {
    enable() {
        this._buttons = new Map();
        this._hoveredAction = null;
        this._popup = new St.BoxLayout({vertical: true, can_focus: false});
        this._navigation = new CandidateNavigation({
            select: selection => { if (selection) this._call('Select', selection); },
            changed: () => { if (this._lastSnapshot) this._render(this._lastSnapshot); },
            preview: item => {
                if (!item) this._refreshDetails();
                else if (this._detailState) this._details.update({...this._detailState, text: item.detailDescription});
            },
        });
        this._popup.add_child(this._navigation.actor);
        this._treeScroll = new St.ScrollView({
            reactive: true, can_focus: false,
            hscrollbar_policy: St.PolicyType.AUTOMATIC,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            style: 'background-color: transparent; border: none; box-shadow: none;',
        });
        this._content = new St.BoxLayout({vertical: true});
        this._canvas = new St.Widget({layout_manager: new Clutter.FixedLayout(),
            style: 'background-color: #202124; border-radius: 6px;'});
        this._content.add_child(this._canvas);
        this._treeScroll.set_child(this._content);
        this._popup.add_child(this._treeScroll);
        this._details = new CandidateDetail();
        this._popup.add_child(this._details.actor);
        this._interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        Main.layoutManager.addTopChrome(this._popup);
        this._popup.hide();
        this._layoutDiagnostics = new LayoutDiagnostics();
        this._cursor = new ShellCursor(() => {
            if (this._popup.visible && this._lastSnapshot) this._render(this._lastSnapshot);
        });
        this._subscription = Gio.DBus.session.signal_subscribe(NAME, NAME, null, PATH, null,
            Gio.DBusSignalFlags.NONE, (_connection, _sender, _path, _interface, signal, parameters) => {
                if (signal === 'Hide') {
                    this._hoveredAction = null;
                    this._popup.hide();
                    this._lastSnapshot = null;
                    this._placementSide = null;
                    this._layoutDiagnostics.clear();
                    this._navigation.collapse();
                }
                if (signal === 'ScrollDetails' && this._popup.visible)
                    this._details.scrollPage(parameters.deepUnpack()[0]);
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
        this._lastSnapshot = data;
        const anchor = this._cursor.anchor(data.location);
        const nodes = data.nodes ?? [];
        const candidateIdentity = JSON.stringify([data.contextId, data.reading, data.candidates,
            nodes.map(({relativeScore, preview, previewDescription, ...node}) => node)]);
        if (candidateIdentity !== this._candidateIdentity) {
            this._hoveredAction = null;
            for (const widget of this._buttons.values()) widget.destroy();
            this._buttons.clear();
            this._candidateIdentity = candidateIdentity;
        }
        if (!nodes.length) {
            this._navigation.collapse();
            this._popup.hide();
            this._layoutDiagnostics.clear();
            this._canvas.destroy_all_children();
            this._buttons.clear();
            return;
        }
        // Keep AT objects when the same candidate remains visible.
        const retained = new Set(this._buttons.values());
        for (const child of this._canvas.get_children()) {
            if (!retained.has(child)) child.destroy();
        }
        const visibleButtons = new Set();
        const byId = new Map(nodes.map(node => [node.id, node]));
        const columns = data.columns ?? [];
        if (!columns.length) {
            this._navigation.collapse();
            this._popup.hide();
            this._layoutDiagnostics.clear();
            return;
        }
        const frames = new Map();
        const documentWidths = data.wordGeometry?.widths ?? [];
        const fontSize = (data.candidateTextSize === 'large' ? 24 : 18) *
            Math.max(1, this._interfaceSettings.get_double('text-scaling-factor'));
        const minimumWidth = fontSize + (data.showCandidateIndex ? 14 : 8);
        const aligned = anchor.permitsWordAlignment && documentWidths.length === columns.length &&
            documentWidths.every(width => Number.isFinite(width) && width >= minimumWidth);
        const alignmentReason = aligned ? 'estimated-inline' :
            (data.layoutReason ?? (anchor.permitsWordAlignment
                ? (documentWidths.length ? 'column-too-narrow' : 'missing-word-geometry') : 'caret-only'));
        const rowHeight = fontSize + 14;
        const rowPitch = rowHeight + (data.showCandidateIndex && aligned ? rowHeight + 20 : 20);
        const scoreColor = score => Number.isFinite(score) && score < 75 ? '#d4630f' : '#4073cc';
        let nextX = 12;
        for (const [depth, column] of columns.entries()) {
            const measure = new St.Label({text: byId.get(column[0]).text, style: `font-size: ${fontSize}px;`});
            // St needs a stage-backed theme node even for a temporary measurement.
            this._canvas.add_child(measure);
            const columnWidth = aligned ? documentWidths[depth] : Math.max(fontSize + 12, Math.min(240, measure.get_preferred_width(-1)[1] + 12));
            measure.destroy();
            column.forEach((id, row) => frames.set(id, {x: nextX, y: 6 + row * rowPitch, width: columnWidth, height: rowHeight}));
            nextX += columnWidth + (aligned ? 0 : (data.showCandidateIndex ? rowHeight + 2 : 12));
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
        const button = ({operation, index, label, frame, active, focused, accessibleName, score}) => {
            const compactBadge = operation === 'select' && aligned;
            const identity = JSON.stringify([operation, index]);
            let widget = this._buttons.get(identity);
            if (!widget) {
                widget = new St.Button({can_focus: false, reactive: true, track_hover: true, accessible_name: accessibleName});
                widget.connect('button-press-event', () => {
                    widget._pressedSelection = widget._selection;
                    return Clutter.EVENT_PROPAGATE;
                });
                widget.connect_after('button-release-event', () => {
                    widget._pressedSelection = null;
                    return Clutter.EVENT_PROPAGATE;
                });
                // StButton's native activation also serves assistive technology.
                widget.connect('clicked', () => {
                    const selection = widget._pressedSelection ?? widget._selection;
                    widget._pressedSelection = null;
                    if (this._buttons.get(identity) === widget && this._popup.visible)
                        this._call('Select', selection);
                });
                widget.connect('notify::hover', () => {
                    if (this._buttons.get(identity) !== widget) return;
                    if (widget.hover) this._hoveredAction = {identity, operation, index};
                    else if (this._hoveredAction?.identity === identity) this._hoveredAction = null;
                    this._refreshDetails();
                });
                this._canvas.add_child(widget);
                this._buttons.set(identity, widget);
            }
            widget.accessible_name = accessibleName;
            visibleButtons.add(identity);
            widget._selection = new GLib.Variant('(sibis)', [operation, index, true, data.generation, data.contextId]);
            widget.set_checked(active);
            widget.set_style(`color: ${active ? '#ffffff' : '#eeeeef'}; background-color: ${active ? scoreColor(score) : '#24252b'}; border: none; border-bottom: ${compactBadge ? '0' : (focused ? '2px solid #ffffff' : '2px solid transparent')}; border-radius: 4px; padding: ${compactBadge ? 0 : 2}px; font-size: 12px;`);
            const captions = new St.BoxLayout({vertical: true, y_align: Clutter.ActorAlign.CENTER});
            const caption = new St.Label({text: label, x_align: aligned ? Clutter.ActorAlign.START : Clutter.ActorAlign.CENTER});
            const size = operation === 'select' ? Math.max(14, fontSize - 4) : fontSize;
            caption.set_style(`font-size: ${size}px;`);
            caption.set_width(Math.max(1, frame.width - 4));
            captions.add_child(caption);
            widget.set_child(captions);
            widget.set_position(frame.x, frame.y);
            widget.set_size(frame.width, frame.height);
            this._canvas.set_child_above_sibling(widget, null);
        };
        for (const [id, frame] of frames) {
            const node = byId.get(id);
            const score = node.relativeScore;
            const detail = Number.isFinite(score)
                ? `相対スコア ${score}（取得候補内の評価。正解の確率ではありません）` : '比較可能なスコアなし';
            button({operation: 'node', index: id, label: node.text, frame,
                active: selected.has(id), focused: id === data.focusedNode,
                accessibleName: `${node.text} ${node.reading}\n${node.previewDescription ?? ''}`, score});
            const scoreText = Number.isFinite(score) ? String(score) : '—';
            const scoreLabel = new St.Label({text: scoreText, accessible_name: detail,
                style: 'color: #a9a9b0; font-size: 12px;',
                x_align: Clutter.ActorAlign.CENTER});
            scoreLabel.set_position(frame.x, frame.y + frame.height);
            scoreLabel.set_size(frame.width, 16);
            this._canvas.add_child(scoreLabel);
            const index = node.terminals.includes(data.selection) ? data.selection : node.terminals[0];
            if (data.showCandidateIndex && index !== undefined) {
                const number = index - (data.pageStart ?? 0) + 1;
                if (number >= 1 && number <= 9) {
                    const item = data.candidatePage?.items?.find(candidate => candidate.index === index);
                    const numberDescription = [`候補 ${index + 1} を確定`, item?.detailDescription].filter(Boolean).join('\n');
                    button({operation: 'select', index, label: String(number), frame: {
                        x: aligned ? frame.x + frame.width - rowHeight : frame.x + frame.width + 1,
                        y: aligned ? frame.y + frame.height + 16 : frame.y,
                        width: rowHeight, height: rowHeight,
                    }, active: index === data.selection, focused: false, accessibleName: numberDescription});
                }
            }
        }
        for (const [identity, widget] of this._buttons) {
            if (!visibleButtons.has(identity)) {
                if (this._hoveredAction?.identity === identity) this._hoveredAction = null;
                widget.destroy();
                this._buttons.delete(identity);
            }
        }
        const [x, y] = anchor.location;
        const monitorIndex = Main.layoutManager.monitors.findIndex(m => x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height);
        const index = monitorIndex >= 0 ? monitorIndex : Main.layoutManager.primaryIndex;
        const bounds = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(index);
        const detailHeight = Math.min(160, bounds.height / 3);
        const navigationHeight = this._navigation.update(data,
            {fontSize, listHeight: Math.min(240, bounds.height / 3)});
        const placement = candidatePlacement({cursor: anchor.location, bounds,
            contentWidth: width, contentHeight: height, detailHeight: detailHeight + navigationHeight, aligned,
            preferredSide: this._placementSide});
        if (aligned && !placement.permitsAlignment) {
            this._render({...data, wordGeometry: null, layoutReason: 'outside-workarea'});
            return;
        }
        // The popup follows the compact content; there is no full-window backdrop.
        // Reserve a bounded detail area, leaving the source document visible.
        const {width: popupWidth, height: popupHeight, treeHeight} = placement;
        this._treeScroll.set_size(popupWidth, treeHeight);
        this._navigation.actor.set_size(popupWidth, navigationHeight);
        this._details.actor.set_size(popupWidth, detailHeight);
        this._popup.set_size(popupWidth, popupHeight);
        this._detailState = {nodes: byId, fontSize, width: popupWidth};
        this._refreshDetails();
        this._popup.set_position(placement.x, placement.y);
        this._placementSide = placement.side;
        this._layoutDiagnostics.update({source: anchor.source, aligned, reason: alignmentReason,
            cursor: anchor.location, bounds, placement});
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
                reveal(this._treeScroll.get_hadjustment(), Math.max(0, focus.x - 8), focus.x + focus.width + rowHeight + 2);
                reveal(this._treeScroll.get_vadjustment(), Math.max(0, focus.y - 8), focus.y + focus.height + 16);
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    _showDetails(nodeID) {
        const state = this._detailState;
        const node = state?.nodes.get(nodeID);
        if (!node) return;
        const text = [node.text, node.reading, node.previewDescription, messages.detailKeys].filter(Boolean).join('\n');
        this._details.update({text, fontSize: state.fontSize, width: state.width});
    }

    _showNumberDetails(index) {
        if (!this._detailState) return;
        // The numbered action commits this entry even when the word is shared.
        const item = this._lastSnapshot?.candidatePage?.items?.find(candidate => candidate.index === index);
        this._details.update({...this._detailState, text: item?.detailDescription ?? ''});
    }

    _refreshDetails() {
        if (!this._detailState) return;
        const item = this._navigation.expanded ? this._navigation.hoveredItem : null;
        if (item) {
            this._details.update({...this._detailState, text: item.detailDescription});
            return;
        }
        const target = this._hoveredAction;
        if (target && this._buttons.has(target.identity)) {
            if (target.operation === 'node') this._showDetails(target.index);
            else this._showNumberDetails(target.index);
            return;
        }
        const snapshot = this._lastSnapshot;
        this._showDetails(snapshot?.focusedNode ?? snapshot?.columns?.[0]?.[0]);
    }

    disable() {
        this._call('SetRenderer', new GLib.Variant('(b)', [false]));
        if (this._watch) Gio.bus_unwatch_name(this._watch);
        if (this._subscription) Gio.DBus.session.signal_unsubscribe(this._subscription);
        if (this._scrollIdle) GLib.source_remove(this._scrollIdle);
        this._scrollIdle = 0;
        this._focusKey = null;
        this._hoveredAction = null;
        this._cursor?.destroy();
        this._cursor = null;
        this._layoutDiagnostics?.destroy();
        this._layoutDiagnostics = null;
        this._lastSnapshot = null;
        this._popup?.destroy();
        this._buttons?.clear();
        this._popup = null;
    }
}
