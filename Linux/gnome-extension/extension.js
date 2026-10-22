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
import {ShellCursor} from './shellCursor.js';
import {LayoutDiagnostics} from './layoutDiagnostics.js';
import {CandidateNavigation} from './candidateNavigation.js';
import {serializeCandidateIdentity} from './candidateIdentity.js';
import {CandidateTheme} from './candidateTheme.js';
import {attachCandidateAction, CandidateAnnouncements} from './candidateAccessibility.js';
import {addScoreBadge} from './candidateScore.js';

const NAME = 'org.azookey.Tree';
const PATH = '/org/azookey/Tree';
const NODE_BORDER_WIDTH = 2; // Core's node frame includes both borders.
const LINE_HEIGHT_SAMPLE = 'あg'; // A kana and a descender give the tallest candidate line.
// Bound each scrollable section so the source document remains visible around the card.
const CARD_FRACTIONS = {composition: 0.26, details: 0.14, tree: 0.35, list: 0.45};
// St.DrawingArea paints into a texture; tiles stay below GPU texture limits.
const EDGE_TILE_SIZE = 512;

export default class AzooKeyTreeExtension extends Extension {
    enable() {
        this._buttons = new Map();
        this._hoveredAction = null;
        this._treeExpanded = false;
        this._presentationMode = null;
        this._layoutGeneration = 0;
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
        // A snapshot awaiting Core's layout is not visible yet; it still follows these changes.
        this._theme = new CandidateTheme(() => {
            if (this._lastSnapshot) this._render(this._lastSnapshot);
        });
        Main.layoutManager.addTopChrome(this._popup);
        this._popup.hide();
        this._layoutDiagnostics = new LayoutDiagnostics();
        this._cursor = new ShellCursor(() => {
            if (this._lastSnapshot) this._render(this._lastSnapshot);
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

    // A Core layout requested for an older snapshot or a hidden popup is ignored.
    _retireLayout() {
        this._layoutGeneration++;
    }

    _hideCandidates() {
        this._retireLayout();
        this._hoveredAction = null;
        this._candidateIdentity = null;
        this._announcements.reset();
        this._popup.hide();
        this._lastSnapshot = null;
        this._placementSide = null;
        this._layoutDiagnostics.clear();
        this._treeExpanded = false;
        this._treeExpandedFor = null;
        this._presentationMode = null;
        this._navigation.reset();
        this._details.reset();
        this._composition.retire();
        this._detailsShown = false;
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
        this._retireLayout();
        this._popup.hide();
        this._lastSnapshot = null;
        this._detailsShown = false;
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

    // Core lays out candidates after the conversion requests queued before it.
    _requestLayout(request, done) {
        Gio.DBus.session.call(NAME, PATH, NAME, 'Layout', new GLib.Variant('(s)', [JSON.stringify(request)]),
            new GLib.VariantType('(s)'), Gio.DBusCallFlags.NONE, -1, null, (connection, result) => {
                let layout = null;
                try {
                    layout = JSON.parse(connection.call_finish(result).deepUnpack()[0]);
                } catch (error) {
                    console.error('azooKey candidate layout failed', error);
                }
                done(layout);
            });
    }

    _measureText(text, size) {
        const label = new St.Label({text, style: `font-size: ${size}px;`});
        // A stage-backed theme node supplies the actual scaled font metrics.
        this._canvas.add_child(label);
        const dimensions = {width: label.get_preferred_width(-1)[1], height: label.get_preferred_height(-1)[1]};
        label.destroy();
        return dimensions;
    }

    _workArea([x, y]) {
        const monitorIndex = Main.layoutManager.monitors.findIndex(m => x >= m.x && x < m.x + m.width && y >= m.y && y < m.y + m.height);
        const index = monitorIndex >= 0 ? monitorIndex : Main.layoutManager.primaryIndex;
        return global.workspace_manager.get_active_workspace().get_work_area_for_monitor(index);
    }

    _render(data) {
        this._lastSnapshot = data;
        const display = data.candidateDisplay;
        const palette = this._theme.palette;
        this._popup.set_style(`background-color: ${palette.background}; color: ${palette.text};
            border: 1px solid ${palette.border}; border-radius: 12px;`);
        this._canvas.set_style(`background-color: ${palette.background};`);
        this._details.applyPalette(palette);
        // The engine sends an empty snapshot after focus moves away.
        if (!display || display.mode === 'hidden') {
            this._hideCandidates();
            this._canvas.destroy_all_children();
            return;
        }
        const presentationMode = display.mode;
        const candidateIdentity = serializeCandidateIdentity([data.contextId, data.reading, data.candidates,
            data.nodes.map(({relativeScore, scorePresentation, preview, previewDescription, ...node}) => node)]);
        if (candidateIdentity !== this._candidateIdentity || presentationMode !== this._presentationMode) {
            this._navigation.reset();
            this._details.reset();
            this._composition.retire();
            this._treeExpanded = presentationMode === 'tree';
            this._presentationMode = presentationMode;
            this._cancelReveal();
            this._hoveredAction = null;
            this._candidateIdentity = candidateIdentity;
        }
        const expansion = JSON.stringify([data.contextId, data.generation]);
        if (display.expandTree && expansion !== this._treeExpandedFor) {
            // Core asks once per reply; redrawing the same reply keeps the user's choice.
            this._treeExpanded = true;
            this._treeExpandedFor = expansion;
        }
        const actionIdentity = JSON.stringify([candidateIdentity, data.generation, data.selection, data.focusedNode,
            presentationMode, this._treeExpanded]);
        if (actionIdentity !== this._actionIdentity) {
            this._clearButtons();
            this._actionIdentity = actionIdentity;
        }
        this._retireLayout();
        const generation = this._layoutGeneration;
        const anchor = this._cursor.anchor(data.location);
        const bounds = this._workArea(anchor.location);
        const request = this._layoutRequest(data, {anchor, bounds});
        this._requestLayout(request, layout => {
            if (generation !== this._layoutGeneration) return;
            if (!layout) {
                this._suspendCandidates();
                return;
            }
            this._drawTree(data, layout.tree, palette);
            const height = this._layoutCard(data, {bounds, layout, limit: bounds.height});
            // GNOME has no document word widths, so Core never changes this
            // width for alignment and one measurement is enough.
            this._placeCard(data, {request, anchor, bounds, height, generation});
        });
    }

    // Core places whole pixels. When the chosen side is shorter than the card,
    // the card's scrollable regions shrink and Core places the result again.
    _placeCard(data, {request, anchor, bounds, height, generation, fitted = false}) {
        const popupHeight = Math.ceil(height);
        this._requestLayout({...request, popupHeight, preferredSide: this._placementSide ?? null}, placed => {
            if (generation !== this._layoutGeneration) return;
            if (placed?.placementStatus !== 'placed') {
                this._suspendCandidates();
                return;
            }
            if (!fitted && placed.placement.height < popupHeight) {
                this._placementSide = placed.placement.side;
                const fittedHeight = this._layoutCard(data, {bounds, layout: placed, limit: placed.placement.height});
                this._placeCard(data, {request, anchor, bounds, height: fittedHeight, generation, fitted: true});
                return;
            }
            this._place(data, {anchor, bounds, layout: placed});
        });
    }

    _layoutRequest(data, {anchor, bounds}) {
        const display = data.candidateDisplay;
        const nodes = new Map(data.nodes.map(node => [node.id, node]));
        const baseSize = display.baseFontSize;
        const [x, y, width, height] = anchor.location;
        return {
            mode: display.mode === 'list' ? 'list' : 'tree',
            textSize: data.candidateTextSize ?? 'standard',
            textScale: this._interfaceSettings.get_double('text-scaling-factor'),
            measuredFontSize: baseSize,
            lineHeight: this._measureText(LINE_HEIGHT_SAMPLE, baseSize).height + NODE_BORDER_WIDTH * 2,
            columns: (this._treeExpanded ? display.columns : []).map(column => ({
                nodes: column.map(id => ({id, parent: nodes.get(id).parent ?? null})),
                textWidth: this._measureText(nodes.get(column[0]).text, baseSize).width,
            })),
            documentWordWidths: null,
            columnAnchorX: null,
            showScores: Boolean(data.showRelativeScores),
            showNumbers: Boolean(display.showsNumbers),
            cursor: {x, y, width, height},
            workArea: {x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height},
            popupHeight: null,
            preferredSide: this._placementSide ?? null,
        };
    }

    _drawTree(data, tree, palette) {
        // Geometry/theme updates keep AT objects with the same action target.
        const retained = new Set(this._buttons.values());
        for (const child of this._canvas.get_children()) {
            if (!retained.has(child)) child.destroy();
        }
        const {width, height} = tree.contentSize;
        this._canvas.set_size(width, tree.nodes.length ? height : 0);
        const displayed = new Map(data.candidateDisplay.nodes.map(node => [node.id, node]));
        this._drawEdges(tree, displayed);
        const sources = new Map(data.nodes.map(node => [node.id, node]));
        const visibleButtons = new Set();
        for (const node of tree.nodes) {
            const identity = this._renderNodeButton(data, {node, displayed: displayed.get(node.id),
                source: sources.get(node.id), metrics: tree.metrics, palette});
            visibleButtons.add(identity);
            const presentation = data.showRelativeScores ? sources.get(node.id).scorePresentation : null;
            if (presentation && node.scoreFrame)
                addScoreBadge(this._canvas, {presentation, frame: node.scoreFrame, metrics: tree.metrics, palette});
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
        this._treeFrames = new Map(tree.nodes.map(node => [node.id, node.frame]));
    }

    _drawEdges(tree, displayed) {
        // A long phrase can have > 300 candidates and exceed the GPU's maximum
        // texture height; bounded tiles keep scrolling valid on virtual and physical GPUs.
        if (!tree.nodes.length) return;
        const {width, height} = tree.contentSize;
        const edges = tree.edges.map(edge => ({...edge, active: Boolean(displayed.get(edge.node)?.selected)}));
        for (let top = 0; top < height; top += EDGE_TILE_SIZE) {
            for (let left = 0; left < width; left += EDGE_TILE_SIZE) {
                const tileWidth = Math.min(EDGE_TILE_SIZE, width - left), tileHeight = Math.min(EDGE_TILE_SIZE, height - top);
                const visibleEdges = edges.filter(edge => edge.end.x >= left && edge.start.x <= left + tileWidth &&
                    Math.max(edge.start.y, edge.end.y) + 3 >= top && Math.min(edge.start.y, edge.end.y) - 3 <= top + tileHeight);
                const lines = new St.DrawingArea({width: tileWidth, height: tileHeight});
                lines.set_position(left, top);
                lines.connect('repaint', area => {
                    const cr = area.get_context();
                    cr.setSourceRGBA(0, 0, 0, 0);
                    cr.paint();
                    cr.translate(-left, -top);
                    for (const edge of visibleEdges) {
                        const middle = (edge.start.x + edge.end.x) / 2;
                        cr.setSourceRGBA(...this._theme.rgb(edge.active ? 'text' : 'border'), 1);
                        cr.setLineWidth(edge.active ? 3 : 1);
                        cr.setDash(edge.active ? [] : [2, 3], 0);
                        cr.moveTo(edge.start.x, edge.start.y);
                        cr.curveTo(middle, edge.start.y, middle, edge.end.y, edge.end.x, edge.end.y);
                        cr.stroke();
                    }
                    if (left === 0 && top === 0) {
                        cr.setSourceRGBA(...this._theme.rgb('text'), 1);
                        cr.arc(tree.rootAnchor.x, tree.rootAnchor.y, 3, 0, Math.PI * 2);
                        cr.fill();
                    }
                    cr.$dispose();
                });
                this._canvas.add_child(lines);
                lines.queue_repaint();
            }
        }
    }

    _renderNodeButton(data, {node, displayed, source, metrics, palette}) {
        const identity = JSON.stringify(['node', node.id]);
        let widget = this._buttons.get(identity);
        if (!widget) {
            widget = new St.Button({can_focus: false, reactive: true, track_hover: true});
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
                if (widget.hover) this._hoveredAction = {identity, index: node.id};
                else if (this._hoveredAction?.identity === identity) this._hoveredAction = null;
                this._refreshDetails();
            });
            this._canvas.add_child(widget);
            this._buttons.set(identity, widget);
        }
        widget.accessible_name = displayed.accessibleName;
        widget.get_accessible().accessible_description = displayed.accessibleDescription;
        widget._selection = new GLib.Variant('(sibis)', ['node', node.id, false, data.generation, data.contextId]);
        widget.set_checked(displayed.selected);
        widget.set_style(`color: ${displayed.selected ? palette.selectionText : palette.text};
            background-color: ${displayed.selected ? palette.selection : palette.surface};
            border: ${NODE_BORDER_WIDTH}px solid ${displayed.selected ? palette.text : 'transparent'};
            border-radius: 4px; padding: 0;`);
        const content = this._nodeContent({node, displayed, source, metrics});
        widget.set_child(content);
        widget._numberBadge = content._numberBadge;
        widget.set_position(node.frame.x, node.frame.y);
        widget.set_size(node.frame.width, node.frame.height);
        this._canvas.set_child_above_sibling(widget, null);
        return identity;
    }

    // The word, the score line Core reserves, and the number badge, inside both borders.
    _nodeContent({node, displayed, source, metrics}) {
        const {frame, textFrame, numberFrame} = node;
        const innerWidth = Math.max(1, frame.width - NODE_BORDER_WIDTH * 2);
        const innerHeight = frame.height - NODE_BORDER_WIDTH * 2;
        const content = new St.BoxLayout({vertical: true});
        content.set_size(innerWidth, innerHeight);
        const caption = new St.Label({text: source.text, x_align: Clutter.ActorAlign.CENTER,
            y_align: Clutter.ActorAlign.CENTER});
        caption.set_style(`font-size: ${metrics.fontSize}px;`);
        if (displayed.focused) {
            // Text attributes keep the underline inside the glyph layout;
            // an extra CSS border clips enlarged 200% captions.
            const attributes = new Pango.AttrList();
            attributes.insert(Pango.attr_underline_new(Pango.Underline.SINGLE));
            caption.clutter_text.set_attributes(attributes);
        }
        const captionHeight = textFrame.height - NODE_BORDER_WIDTH;
        caption.set_size(innerWidth, captionHeight);
        content.add_child(caption);
        content._numberBadge = null;
        if (!numberFrame || !Number.isInteger(displayed.number)) return content;
        const badgeHeight = numberFrame.height - NODE_BORDER_WIDTH;
        const gap = new St.Widget();
        gap.set_size(innerWidth, Math.max(0, innerHeight - captionHeight - badgeHeight));
        content.add_child(gap);
        const badge = new St.Label({text: String(displayed.number), x_align: Clutter.ActorAlign.START,
            reactive: false, can_focus: false,
            style: `font-size: ${metrics.numberFontSize}px; padding-left: ${numberFrame.x - frame.x - NODE_BORDER_WIDTH}px;`});
        badge.set_size(innerWidth, badgeHeight);
        content.add_child(badge);
        content._numberBadge = badge;
        return content;
    }

    // Returns the popup height the card needs within `limit`.
    _layoutCard(data, {bounds, layout, limit}) {
        const isList = data.candidateDisplay.mode === 'list';
        const popupWidth = layout.popupWidth;
        const fontSize = layout.tree.metrics.fontSize;
        const treeContentHeight = layout.tree.nodes.length ? layout.tree.contentSize.height : 0;
        for (const actor of [this._composition.actor, this._navigation.actor, this._details.actor]) actor.visible = isList;
        this._detailsShown = isList;
        if (!isList) {
            const treeHeight = Math.min(treeContentHeight, bounds.height * CARD_FRACTIONS.tree, limit);
            this._treeScroll.show();
            this._treeScroll.set_size(popupWidth, treeHeight);
            this._popup.set_size(popupWidth, treeHeight);
            return treeHeight;
        }
        // Three independently scrollable regions keep long sentences and enlarged text reachable.
        const palette = this._theme.palette;
        const compositionHeight = this._composition.update(data,
            {fontSize, width: popupWidth, maximumHeight: limit * CARD_FRACTIONS.composition, palette});
        const navigationMinimum = this._navigation.update(data,
            {fontSize, width: popupWidth, listHeight: 1, palette});
        this._refreshDetails();
        const detailHeight = this._details.layout({identity: this._actionIdentity, treeExpanded: this._treeExpanded,
            fontSize, width: popupWidth, maximumHeight: limit * CARD_FRACTIONS.details});
        const available = Math.max(1, limit - compositionHeight - detailHeight - navigationMinimum - 2);
        const treeHeight = this._treeExpanded ? Math.min(treeContentHeight, available * CARD_FRACTIONS.tree) : 0;
        const navigationHeight = this._navigation.update(data,
            {fontSize, width: popupWidth, listHeight: Math.min(available - treeHeight, limit * CARD_FRACTIONS.list), palette});
        this._navigation.actor.set_size(popupWidth, navigationHeight);
        this._treeScroll.visible = this._treeExpanded;
        this._treeScroll.set_size(popupWidth, treeHeight);
        const height = compositionHeight + navigationHeight + detailHeight + treeHeight;
        this._popup.set_size(popupWidth, height);
        return height;
    }

    _place(data, {anchor, bounds, layout}) {
        const placement = layout.placement;
        const wasVisible = this._popup.visible;
        this._popup.set_position(placement.x, placement.y);
        this._popup.set_size(placement.width, placement.height);
        this._placementSide = placement.side;
        this._layoutDiagnostics.update({source: anchor.source, aligned: layout.tree.aligned, reason: layout.tree.reason,
            cursor: anchor.location, bounds, placement});
        this._popup.show();
        this._announcements.update(data);
        this._revealFocus(data);
        // St measures the labels of a hidden popup too short; measure once more
        // now that it is mapped, so no sentence line is clipped.
        if (!wasVisible) this._render(data);
    }

    _revealFocus(data) {
        const focus = this._treeFrames?.get(data.focusedNode);
        const focusKey = `${data.contextId}:${data.selection}:${data.focusedNode}`;
        if (!this._treeExpanded || !focus || focusKey === this._focusKey) return;
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

    _showDetails(nodeID) {
        const node = this._lastSnapshot?.candidateDisplay.nodes.find(item => item.id === nodeID);
        if (node) this._details.update({text: node.detailText});
    }

    _refreshDetails() {
        if (!this._detailsShown) return;
        const item = this._navigation.expanded ? this._navigation.hoveredItem : null;
        if (item) {
            this._details.update({text: item.detailText});
            return;
        }
        const target = this._hoveredAction;
        if (target && this._buttons.has(target.identity)) {
            this._showDetails(target.index);
            return;
        }
        this._showDetails(this._lastSnapshot?.candidateDisplay.detailNode);
    }

    disable() {
        this._call('SetRenderer', new GLib.Variant('(b)', [false]));
        if (this._watch) Gio.bus_unwatch_name(this._watch);
        if (this._subscription) Gio.DBus.session.signal_unsubscribe(this._subscription);
        this._retireLayout();
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
