import * as IBusManager from 'resource:///org/gnome/shell/misc/ibusManager.js';
import {translateCursorLocation, validCursorLocation} from './candidatePlacement.js';

// GNOME 46 forwards Wayland rectangles only to its panel service, not the engine.
// Keep the version-specific adapter here; its absence leaves the engine fallback.
export class ShellCursor {
    constructor(changed) {
        this._changed = changed;
        this._manager = IBusManager.getIBusManager();
        this._readySignal = this._manager.connect('ready', () => this._connectPanel());
        this._focusSignal = global.display.connect('notify::focus-window', () => this._clear());
        this._connectPanel();
    }

    _connectPanel() {
        this._disconnectPanel();
        const panel = this._manager._panelService;
        if (!panel) return;
        this._panel = panel;
        this._panelSignals = [
            panel.connect('set-cursor-location', (_panel, x, y, width, height) =>
                this._update([x, y, width, height], false)),
            panel.connect('set-cursor-location-relative', (_panel, x, y, width, height) =>
                this._update([x, y, width, height], true)),
            panel.connect('focus-in', () => this._clear()),
            panel.connect('focus-out', () => this._clear()),
        ];
    }

    _update(location, relative) {
        this._clear();
        if (!validCursorLocation(location)) return;
        this._location = location;
        this._relative = relative;
        if (relative) {
            this._window = global.display.focus_window;
            if (!this._window) return;
            this._windowSignals = [
                this._window.connect('position-changed', () => this._changed()),
                this._window.connect('size-changed', () => this._changed()),
            ];
        }
        this._changed();
    }

    anchor(engineLocation) {
        if (this._relative) {
            const actor = this._window?.get_compositor_private();
            const location = actor && translateCursorLocation(this._location, [actor.x, actor.y]);
            if (location) return {location, source: 'wayland-relative', permitsWordAlignment: false};
        }
        if (validCursorLocation(engineLocation))
            return {location: engineLocation, source: 'engine', permitsWordAlignment: true};
        if (validCursorLocation(this._location))
            return {location: this._location, source: 'shell', permitsWordAlignment: false};
        return {location: [0, 0, 0, 0], source: 'unavailable', permitsWordAlignment: false};
    }

    _clear() {
        for (const signal of this._windowSignals ?? []) this._window.disconnect(signal);
        this._windowSignals = [];
        this._window = null;
        this._location = null;
        this._relative = false;
    }

    _disconnectPanel() {
        this._clear();
        for (const signal of this._panelSignals ?? []) this._panel.disconnect(signal);
        this._panelSignals = [];
        this._panel = null;
    }

    destroy() {
        this._disconnectPanel();
        this._manager.disconnect(this._readySignal);
        global.display.disconnect(this._focusSignal);
    }
}
