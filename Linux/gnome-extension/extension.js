import Atk from 'gi://Atk';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Pango from 'gi://Pango';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {CandidateDetail} from './candidateDetail.js';
import {CandidateComposition} from './candidateComposition.js';
import {messages} from './candidateMessages.js';
import {candidatePlacement} from './candidatePlacement.js';
import {ShellCursor} from './shellCursor.js';
import {LayoutDiagnostics} from './layoutDiagnostics.js';
import {CandidateNavigation} from './candidateNavigation.js';
import {CandidateTheme} from './candidateTheme.js';
import {attachCandidateAction, CandidateAnnouncements} from './candidateAccessibility.js';
import {addScoreBadge, SCORE_LINE_HEIGHT} from './candidateScore.js';

const NAME = 'org.azookey.Tree';
const PATH = '/org/azookey/Tree';
const CANDIDATE_ROW_GAP = 4; // Separate actions even when the score line is hidden.
const MINIMUM_NODE_HEIGHT = 44; // A number badge shares the word's pointer/AT target.
const NODE_BORDER_WIDTH = 2; // Reserve both borders outside the measured label heights.
// Bound each scrollable section so the source document remains visible around the card.
const CARD_LAYOUT = {minimumWidth: 360, maximumWidth: 560, lineCharacters: 26,
    compositionFraction: 0.26, detailsFraction: 0.14, treeFraction: 0.35, listFraction: 0.45};

export default class AzooKeyTreeExtension extends Extension {
    enable() {
        this._buttons = new Map();
        this._hoveredAction = null;
        this._treeExpanded = false;
        this._presentationMode = null;
        this._popup = new St.BoxLayout({vertical: true, can_focus: false});
        this._announcements = new CandidateAnnouncements(announcement =>
            this._popup.get_accessible().emit('notification', announcement, Atk.Live.POLITE));
        this._composition = new CandidateComposition(selection => this._call('Select', selection));
        this._popup.add_child(this._composition.actor);
        this._navigation = new CandidateNavigation({
            select: selection => { if (selection) this._call('Select', selection); },
            changed: () => { if (this._lastSnapshot) this._render(this._lastSnapshot); },
            preview: () => this._refreshDetails(),
        });
        this._popup.add_child(this._navigation.actor);
        this._treeScroll = new St.ScrollView({
            reactive: true, can_focus: false,
            hscrollbar_policy: St.PolicyType.AUTOMATIC,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            style: 'background-color: transparent; border: none; box-shadow: none;',
        });
        this._content = new St.BoxLayout({vertical: true});
        this._canvas = new St.Widget({layout_manager: new Clutter.FixedLayout()});
        this._content.add_child(this._canvas);
        this._treeScroll.set_child(this._content);
        this._popup.add_child(this._treeScroll);
        this._details = new CandidateDetail({
            changed: () => { if (this._lastSnapshot) this._render(this._lastSnapshot); },
            toggleTree: () => {
                this._treeExpanded = !this._treeExpanded;
                if (this._lastSnapshot) this._render(this._lastSnapshot);
            },
        });
        this._popup.add_child(this._details.actor);
        this._interfaceSettings = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._theme = new CandidateTheme(() => {
            if (this._popup.visible && this._lastSnapshot) this._render(this._lastSnapshot);
        });
        Main.layoutManager.addTopChrome(this._popup);
        this._popup.hide();
        this._layoutDiagnostics = new LayoutDiagnostics();
        this._cursor = new ShellCursor(() => {
            if (this._popup.visible && this._lastSnapshot) this._render(this._lastSnapshot);
        });
        this._subscription = Gio.DBus.session.signal_subscribe(NAME, NAME, null, PATH, null,
            Gio.DBusSignalFlags.NONE, (_connection, _sender, _path, _interface, signal, parameters) => {
                if (signal === 'Suspend') this._suspendCandidates();
                if (signal === 'Hide') {
                    this._hideCandidates();
                }
                if (signal === 'ScrollDetails' && this._popup.visible)
                    this._details.scrollPage(parameters.deepUnpack()[0]);
                if (signal === 'Update') {
                    try { this._render(JSON.parse(parameters.deepUnpack()[0])); }
                    catch (error) {
                        console.error('azooKey candidate rendering failed', error);
                        this._hideCandidates();
                        this._call('SetRenderer', new GLib.Variant('(b)', [false]));
                    }
                }
            });
        this._watch = Gio.bus_watch_name(Gio.BusType.SESSION, NAME, Gio.BusNameWatcherFlags.NONE,
            () => this._call('SetRenderer', new GLib.Variant('(b)', [true])),
            () => this._hideCandidates());
    }

    _clearButtons() {
        const retired = [...this._buttons.values()];
        // Destroying an actor may emit hover changes; it no longer owns the target.
        this._buttons.clear();
        for (const widget of retired) widget.destroy();
        this._actionIdentity = null;
    }

    _hideCandidates() {
        this._hoveredAction = null;
        this._candidateIdentity = null;
        this._announcements.reset();
        this._popup.hide();
        this._lastSnapshot = null;
        this._placementSide = null;
        this._layoutDiagnostics.clear();
        this._treeExpanded = false;
        this._presentationMode = null;
        this._navigation.reset();
        this._details.reset();
        this._composition.retire();
        this._detailState = null;
        this._cancelReveal();
        this._clearButtons();
    }

    _cancelReveal({preserveFocus = false} = {}) {
        if (this._scrollIdle) GLib.source_remove(this._scrollIdle);
        this._scrollIdle = 0;
        if (!preserveFocus) this._focusKey = null;
    }

    _suspendCandidates() {
        // Keep only presentation preferences. No old action survives the pending interval.
        this._popup.hide();
        this._lastSnapshot = null;
        this._detailState = null;
        this._hoveredAction = null;
        this._navigation.retire({preserveViewport: true});
        this._details.retire();
        this._composition.retire();
        this._cancelReveal({preserveFocus: true});
        this._clearButtons();
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
        const palette = this._theme.palette;
        this._popup.set_style(`background-color: ${palette.background}; color: ${palette.text};
            border: 1px solid ${palette.border}; border-radius: 12px;`);
        this._canvas.set_style(`background-color: ${palette.background};`);
        this._details.applyPalette(palette);
        const nodes = data.nodes ?? [];
        const presentationMode = data.candidateDisplayMode === 'menu' ||
            ['selecting', 'previewing', 'replaceSuggestion'].includes(data.inputState) ? 'menu' : 'live';
        // Live badges identify the preview; only showCandidateIndex advertises physical number keys.
        const showNodeNumbers = presentationMode === 'live' && data.inputState === 'composing' || data.showCandidateIndex === true;
        const candidateIdentity = JSON.stringify([data.contextId, data.reading, data.candidates,
            nodes.map(({relativeScore, scorePresentation, preview, previewDescription, ...node}) => node)]);
        if (candidateIdentity !== this._candidateIdentity || presentationMode !== this._presentationMode) {
            this._navigation.reset();
            this._details.reset();
            this._composition.retire();
            this._treeExpanded = presentationMode === 'live';
            this._presentationMode = presentationMode;
            this._cancelReveal();
            this._hoveredAction = null;
            this._candidateIdentity = candidateIdentity;
        }
        const actionIdentity = JSON.stringify([candidateIdentity, data.generation, data.selection, data.focusedNode,
            presentationMode, this._treeExpanded]);
        if (actionIdentity !== this._actionIdentity) {
            this._clearButtons();
            this._actionIdentity = actionIdentity;
        }
        if (!nodes.length) {
            this._hideCandidates();
            this._canvas.destroy_all_children();
            return;
        }
        // Geometry/theme updates keep AT objects with the same action target.
        const retained = new Set(this._buttons.values());
        for (const child of this._canvas.get_children()) {
            if (!retained.has(child)) child.destroy();
        }
        const visibleButtons = new Set();
        const byId = new Map(nodes.map(node => [node.id, node]));
        const allColumns = data.columns ?? [];
        if (!allColumns.length) {
            this._hideCandidates();
            return;
        }
        const focusedDepth = byId.get(data.focusedNode)?.depth ?? 0;
        // Live input shows branches; the explicit menu expands only the word being edited.
        const columns = !this._treeExpanded ? [] : presentationMode === 'live' ? allColumns :
            allColumns.map((column, depth) => depth === focusedDepth ? column : [data.selectedPath?.[depth] ?? column[0]]);
        const frames = new Map();
        const fontSize = (data.candidateTextSize === 'large' ? 24 : 18) *
            Math.max(1, this._interfaceSettings.get_double('text-scaling-factor'));
        // A sentence/list card follows the caret rather than pretending its rows align to document words.
        const aligned = false;
        const alignmentReason = 'sentence-card';
        const measureText = (text, size) => {
            const label = new St.Label({text, style: `font-size: ${size}px;`});
            // A stage-backed theme node supplies the actual scaled font metrics.
            this._canvas.add_child(label);
            const dimensions = {width: label.get_preferred_width(-1)[1], height: label.get_preferred_height(-1)[1]};
            label.destroy();
            return dimensions;
        };
        const numberFontSize = Math.max(12, fontSize - 8);
        const badgeHeight = showNodeNumbers ? measureText('9', numberFontSize).height : 0;
        const rowHeight = Math.max(MINIMUM_NODE_HEIGHT,
            measureText('あg', fontSize).height + badgeHeight + NODE_BORDER_WIDTH * 2);
        const scoreHeight = data.showRelativeScores ? SCORE_LINE_HEIGHT : 0;
        const rowPitch = rowHeight + scoreHeight + CANDIDATE_ROW_GAP;
        let nextX = 12;
        for (const [depth, column] of columns.entries()) {
            const columnWidth = Math.max(fontSize + 24,
                Math.min(280, measureText(byId.get(column[0]).text, fontSize).width + 24));
            column.forEach((id, row) => frames.set(id, {x: nextX, y: 6 + row * rowPitch, width: columnWidth, height: rowHeight}));
            nextX += columnWidth + 12;
        }
        const width = Math.max(60, nextX);
        const height = columns.length ? Math.max(32, Math.max(...columns.map(column => column.length)) * rowPitch + 6) : 0;
        this._canvas.set_size(width, height);
        const selected = new Set(data.selectedPath ?? []);
        const edges = columns.flat().map(id => {
            const node = byId.get(id);
            const parent = frames.get(node.parent), target = frames.get(id);
            return {x1: parent ? parent.x + parent.width : 4, y1: parent ? parent.y + rowHeight / 2 : 6 + rowHeight / 2,
                x2: target.x, y2: target.y + rowHeight / 2, active: selected.has(id)};
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
                        cr.setSourceRGBA(...this._theme.rgb(edge.active ? 'text' : 'border'), 1);
                        cr.setLineWidth(edge.active ? 3 : 1);
                        cr.setDash(edge.active ? [] : [2, 3], 0);
                        cr.moveTo(edge.x1, edge.y1);
                        cr.curveTo(middle, edge.y1, middle, edge.y2, edge.x2, edge.y2);
                        cr.stroke();
                    }
                    if (left === 0 && top === 0) {
                        cr.setSourceRGBA(...this._theme.rgb('text'), 1);
                        cr.arc(4, 18, 3, 0, Math.PI * 2);
                        cr.fill();
                    }
                    cr.$dispose();
                });
                this._canvas.add_child(lines);
                lines.queue_repaint();
            }
        }
        const renderNodeButton = ({operation, index, label, number, frame, active, focused, accessibleName, description = ''}) => {
            const identity = JSON.stringify([operation, index]);
            let widget = this._buttons.get(identity);
            if (!widget) {
                widget = new St.Button({can_focus: false, reactive: true, track_hover: true, accessible_name: accessibleName});
                attachCandidateAction(widget);
                widget.connect('button-press-event', () => {
                    widget._pressedSelection = widget._selection;
                    return Clutter.EVENT_PROPAGATE;
                });
                widget.connect_after('button-release-event', () => {
                    widget._pressedSelection = null;
                    return Clutter.EVENT_PROPAGATE;
                });
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
            widget.get_accessible().accessible_description = description;
            visibleButtons.add(identity);
            widget._selection = new GLib.Variant('(sibis)', [operation, index, false, data.generation, data.contextId]);
            widget.set_checked(active);
            const textColor = active ? palette.selectionText : palette.text;
            const borderWidth = NODE_BORDER_WIDTH;
            widget.set_style(`color: ${textColor}; background-color: ${active ? palette.selection : palette.surface}; border: ${borderWidth}px solid ${active ? palette.text : 'transparent'}; border-radius: 4px; padding: 0;`);
            const captions = new St.BoxLayout({vertical: true});
            captions.set_size(Math.max(1, frame.width - borderWidth * 2), frame.height - borderWidth * 2);
            const caption = new St.Label({text: label, x_align: Clutter.ActorAlign.CENTER,
                y_expand: true, y_align: Clutter.ActorAlign.CENTER});
            caption.set_style(`font-size: ${fontSize}px;`);
            if (focused) {
                // Text attributes keep the underline inside the glyph layout;
                // an extra CSS border clips enlarged 200% captions.
                const attributes = new Pango.AttrList();
                attributes.insert(Pango.attr_underline_new(Pango.Underline.SINGLE));
                caption.clutter_text.set_attributes(attributes);
            }
            caption.set_width(Math.max(1, frame.width - borderWidth * 2));
            captions.add_child(caption);
            widget._numberBadge = null;
            if (number !== null) {
                const badge = new St.Label({text: String(number), x_align: Clutter.ActorAlign.START,
                    reactive: false, can_focus: false,
                    style: `font-size: ${numberFontSize}px; padding-left: 4px;`});
                captions.add_child(badge);
                widget._numberBadge = badge;
            }
            widget.set_child(captions);
            widget.set_position(frame.x, frame.y);
            widget.set_size(frame.width, frame.height);
            this._canvas.set_child_above_sibling(widget, null);
        };
        const candidateIndices = new Set((data.candidates ?? []).map(candidate => candidate.index));
        for (const [id, frame] of frames) {
            const node = byId.get(id);
            const presentation = data.showRelativeScores ? node.scorePresentation : null;
            const index = node.preview?.candidateIndex;
            const pageNumber = index - (data.pageStart ?? 0) + 1;
            const number = showNodeNumbers && Number.isInteger(index) && index >= 0 && candidateIndices.has(index) &&
                pageNumber >= 1 && pageNumber <= 9 ? pageNumber : null;
            const accessibleName = [node.text, node.reading, number === null ? null : messages.numberBadge(number)]
                .filter(Boolean).join('\n');
            const description = [id === data.focusedNode ? messages.focusedSelect : messages.select,
                node.previewDescription, presentation?.detailDescription].filter(Boolean).join('\n');
            renderNodeButton({operation: 'node', index: id, label: node.text, number, frame,
                active: selected.has(id), focused: id === data.focusedNode,
                accessibleName, description});
            if (presentation) addScoreBadge(this._canvas, {node, frame, palette});
        }
        for (const [identity, widget] of this._buttons) {
            if (!visibleButtons.has(identity)) {
                if (this._hoveredAction?.identity === identity) this._hoveredAction = null;
                widget.destroy();
                this._buttons.delete(identity);
            }
        }
        // Selection changes retire all actors before rebuilding the visible page.
        // A target absent from that page must not regain hover when it reappears.
        if (this._hoveredAction && !visibleButtons.has(this._hoveredAction.identity))
            this._hoveredAction = null;
        const [x, y] = anchor.location;
        const monitorIndex = Main.layoutManager.monitors.findIndex(m => x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height);
        const index = monitorIndex >= 0 ? monitorIndex : Main.layoutManager.primaryIndex;
        const bounds = global.workspace_manager.get_active_workspace().get_work_area_for_monitor(index);
        const placement = this._layoutCard(data, {bounds, fontSize, treeContentWidth: width, treeContentHeight: height,
            nodes: byId, actionIdentity, location: anchor.location, palette});
        this._popup.set_position(placement.x, placement.y);
        this._placementSide = placement.side;
        this._layoutDiagnostics.update({source: anchor.source, aligned, reason: alignmentReason,
            cursor: anchor.location, bounds, placement});
        this._popup.show();
        this._announcements.update(data);
        const focus = frames.get(data.focusedNode);
        const focusKey = `${data.contextId}:${data.selection}:${data.focusedNode}`;
        if (this._treeExpanded && focus && focusKey !== this._focusKey) {
            if (this._scrollIdle) GLib.source_remove(this._scrollIdle);
            this._scrollIdle = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
                this._scrollIdle = 0;
                this._focusKey = focusKey;
                const reveal = (adjustment, start, end) => {
                    let value = adjustment.value;
                    if (start < value) value = start;
                    else if (end > value + adjustment.page_size) value = end - adjustment.page_size;
                    adjustment.value = Math.max(adjustment.lower,
                        Math.min(value, adjustment.upper - adjustment.page_size));
                };
                reveal(this._treeScroll.get_hadjustment(), Math.max(0, focus.x - 8), focus.x + focus.width + 8);
                reveal(this._treeScroll.get_vadjustment(), Math.max(0, focus.y - 8), focus.y + focus.height + 16);
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    _layoutCard(data, {bounds, fontSize, treeContentWidth, treeContentHeight, nodes, actionIdentity, location, palette}) {
        const isMenu = this._presentationMode === 'menu';
        for (const actor of [this._composition.actor, this._navigation.actor, this._details.actor]) actor.visible = isMenu;
        if (!isMenu) {
            this._detailState = null;
            const treeWidth = Math.min(bounds.width, treeContentWidth, CARD_LAYOUT.maximumWidth);
            const treeHeight = Math.min(treeContentHeight, bounds.height * CARD_LAYOUT.treeFraction);
            this._treeScroll.show();
            const placement = candidatePlacement({cursor: location, bounds, contentWidth: treeWidth,
                contentHeight: treeHeight, detailHeight: 0, aligned: false, preferredSide: this._placementSide});
            this._treeScroll.set_size(placement.width, placement.treeHeight);
            this._popup.set_size(placement.width, placement.height);
            return placement;
        }
        // Three independently scrollable regions keep long sentences and enlarged text reachable.
        const popupWidth = Math.min(bounds.width, Math.max(CARD_LAYOUT.minimumWidth,
            Math.min(CARD_LAYOUT.maximumWidth, fontSize * CARD_LAYOUT.lineCharacters)));
        const compositionHeight = this._composition.update(data,
            {fontSize, width: popupWidth, maximumHeight: bounds.height * CARD_LAYOUT.compositionFraction, palette});
        this._detailState = {nodes, showScores: data.showRelativeScores};
        const navigationMinimum = this._navigation.update(data,
            {fontSize, width: popupWidth, listHeight: 1, palette});
        this._refreshDetails();
        const detailHeight = this._details.layout({identity: actionIdentity, treeExpanded: this._treeExpanded,
            fontSize, width: popupWidth, maximumHeight: bounds.height * CARD_LAYOUT.detailsFraction});
        const available = Math.max(1, bounds.height - compositionHeight - detailHeight - navigationMinimum - 2);
        const treeHeight = this._treeExpanded ? Math.min(treeContentHeight, available * CARD_LAYOUT.treeFraction) : 0;
        const navigationHeight = this._navigation.update(data,
            {fontSize, width: popupWidth, listHeight: Math.min(available - treeHeight, bounds.height * CARD_LAYOUT.listFraction), palette});
        this._navigation.actor.set_size(popupWidth, navigationHeight);
        const placement = candidatePlacement({cursor: location, bounds,
            contentWidth: popupWidth, contentHeight: treeHeight,
            detailHeight: compositionHeight + navigationHeight + detailHeight, aligned: false,
            preferredSide: this._placementSide});
        this._treeScroll.visible = this._treeExpanded;
        this._treeScroll.set_size(popupWidth, treeHeight);
        this._popup.set_size(popupWidth, placement.height);
        return placement;
    }

    _showDetails(nodeID) {
        const state = this._detailState;
        const node = state?.nodes.get(nodeID);
        if (!node) return;
        const scoreDescription = state.showScores ? node.scorePresentation?.detailDescription : null;
        const text = [node.text, node.reading, node.previewDescription, scoreDescription, messages.detailKeys].filter(Boolean).join('\n');
        this._details.update({text});
    }

    _refreshDetails() {
        if (!this._detailState) return;
        const item = this._navigation.expanded ? this._navigation.hoveredItem : null;
        if (item) {
            this._details.update({text: item.detailDescription});
            return;
        }
        const target = this._hoveredAction;
        if (target && this._buttons.has(target.identity)) {
            this._showDetails(target.index);
            return;
        }
        const snapshot = this._lastSnapshot;
        this._showDetails(snapshot?.focusedNode ?? snapshot?.columns?.[0]?.[0]);
    }

    disable() {
        this._call('SetRenderer', new GLib.Variant('(b)', [false]));
        if (this._watch) Gio.bus_unwatch_name(this._watch);
        if (this._subscription) Gio.DBus.session.signal_unsubscribe(this._subscription);
        this._cancelReveal();
        this._hoveredAction = null;
        this._cursor?.destroy();
        this._cursor = null;
        this._layoutDiagnostics?.destroy();
        this._layoutDiagnostics = null;
        this._lastSnapshot = null;
        this._announcements.reset();
        this._theme?.destroy();
        this._theme = null;
        this._popup?.destroy();
        this._buttons?.clear();
        this._popup = null;
    }
}
