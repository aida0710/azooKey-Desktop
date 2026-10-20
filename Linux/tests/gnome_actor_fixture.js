import Gio from 'gi://Gio';

const pendingActions = [];

export function drainActions() {
    while (pendingActions.length) pendingActions.shift()();
}

// Model only actors and Cally's deferred delivery; callers use product decisions.
export class Actor {
    constructor(properties = {}) {
        Object.assign(this, {visible: true, reactive: true}, properties);
        this.children = [];
        this.signals = new Map();
        this.clutter_text = {set_attributes() {},
            set_line_wrap: value => { this.wrap = value; },
            set_line_wrap_mode: value => { this.wrapMode = value; },
            set_ellipsize: value => { this.ellipsize = value; }};
        this.adjustment = {value: 0, lower: 0, upper: 600, page_size: 160, connect() {}};
        this.accessible = {
            add_action: (_name, _description, _key, callback) => {
                this.action = () => callback(this.accessible);
                return 1;
            },
            get_object: () => this,
            do_action: () => {
                if (!this.is_mapped() || !this.reactive) return false;
                pendingActions.push(this.action);
                return true;
            },
        };
    }
    connect(signal, callback) {
        const callbacks = this.signals.get(signal) ?? [];
        callbacks.push(callback);
        this.signals.set(signal, callbacks);
    }
    connect_after(signal, callback) { this.connect(signal, callback); }
    emit(signal, ...args) {
        for (const callback of this.signals.get(signal) ?? []) callback(this, ...args);
    }
    get_accessible() { return this.accessible; }
    is_mapped() { return this.visible && (!this.parent || this.parent.is_mapped()); }
    get_parent() { return this.parent; }
    get_children() { return this.children; }
    add_child(child) { this.children.push(child); child.parent = this; }
    set_child(child) { this.add_child(child); }
    set_width(width) { this.width = width; }
    set_size(width, height) { this.width = width; this.height = height; }
    set_position(x, y) { this.x = x; this.y = y; }
    set_style(style) { this.style = style; }
    set_checked(checked) { this.checked = checked; }
    get_preferred_width() { return [40, 80]; }
    get_preferred_height() { return [24, Math.max(36, this.children.length * 44)]; }
    get_vadjustment() { return this.adjustment; }
    get_hadjustment() { return this.adjustment; }
    queue_repaint() {}
    set_child_above_sibling() {}
    hide() { this.visible = false; }
    show() { this.visible = true; }
    destroy() {
        this.visible = false;
        this.hover = false;
        this.emit('notify::hover');
        this.emit('destroy');
        if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this);
        this.parent = null;
    }
    destroy_all_children() { for (const child of [...this.children]) child.destroy(); }
}

export function loadShellClass({fileName, imports, className}) {
    const file = Gio.File.new_for_uri(import.meta.url).get_parent().get_parent()
        .get_child(`gnome-extension/${fileName}`);
    const source = new TextDecoder().decode(file.load_contents(null)[1])
        .replace(/^import .*;\n/gm, '').replace(/^export (default )?/gm, '');
    return new Function(...Object.keys(imports), `${source}\nreturn ${className};`)(...Object.values(imports));
}
