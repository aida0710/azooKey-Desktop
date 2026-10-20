import Gio from 'gi://Gio';

const INTERFACE = `<node><interface name="org.azookey.Tree.Renderer">
    <method name="DescribeLayout"><arg direction="out" type="s"/></method>
</interface></node>`;

// This inspection endpoint contains only coordinates and fixed reason codes.
// Candidate text, reading, context identifiers and client documents stay private.
export class LayoutDiagnostics {
    constructor() {
        this._description = {};
        this._exported = Gio.DBusExportedObject.wrapJSObject(INTERFACE, this);
        this._exported.export(Gio.DBus.session, '/org/azookey/Tree/Renderer');
    }

    update({source, aligned, reason, cursor, bounds, placement}) {
        this._description = {
            renderer: 'gnome-shell', source, mode: aligned ? 'aligned' : 'compact', reason,
            cursor, workArea: [bounds.x, bounds.y, bounds.width, bounds.height],
            popup: [placement.x, placement.y, placement.width, placement.height],
        };
    }

    DescribeLayout() {
        return JSON.stringify(this._description);
    }

    clear() {
        this._description = {};
    }

    destroy() {
        this._exported.unexport();
    }
}
