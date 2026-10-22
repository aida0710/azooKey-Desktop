import Gio from 'gi://Gio';
import GLib from 'gi://GLib';

// GNOME tests build synthetic snapshots without the `candidateDisplay` every
// bridge reply has. The real Swift bridge derives it and lays it out, so the
// tests exercise Core's decisions instead of a JavaScript copy of them.
let bridge = null;

function start() {
    const executable = GLib.getenv('AZOOKEY_BRIDGE');
    if (!executable) throw new Error('AZOOKEY_BRIDGE must name the Swift bridge');
    const process = Gio.Subprocess.new([executable],
        Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_SILENCE);
    return {process, input: process.get_stdin_pipe(),
        output: new Gio.DataInputStream({base_stream: process.get_stdout_pipe()})};
}

function request(operation, payload) {
    bridge ??= start();
    bridge.input.write_all(new TextEncoder().encode(`${JSON.stringify({operation, ...payload})}\n`), null);
    const [line] = bridge.output.read_line_utf8(null);
    return JSON.parse(line);
}

export function withDisplay(snapshot, previous = null) {
    const source = previous ? {...snapshot, previous} : snapshot;
    return {...snapshot, candidateDisplay: request('candidate-display', {snapshot: source}).candidateDisplay};
}

// A synchronous stand-in for the extension's D-Bus Layout call.
export function requestLayout(layout, done) {
    done(request('candidate-layout', {layout}).candidateLayout);
}

export function closeCoreBridge() {
    if (!bridge) return;
    bridge.input.close(null);
    bridge.process.wait(null);
    bridge = null;
}
