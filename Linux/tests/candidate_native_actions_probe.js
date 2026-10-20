// Development-only GNOME probe. Import from a disposable VM's extension and
// call with its real CandidateNavigation and Main.layoutManager. Never ship
// this invocation in the product extension.
import GLib from 'gi://GLib';
import Atk from 'gi://Atk';

const PAINT_DEADLINE_US = 5_000_000;
const PAINT_POLL_MS = 16; // Check the native SHOWING state about once per frame.

export function probeNativeActions(Navigation, layoutManager, report) {
    const submitted = [];
    const navigation = new Navigation({select: action => submitted.push(action.deepUnpack()),
        changed() {}, preview() {}});
    const layout = {fontSize: 18, listHeight: 100};
    const assertions = [];
    let stage = 0;
    function equal(actual, expected) {
        if (JSON.stringify(actual) !== JSON.stringify(expected))
            throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
    }
    function snapshot(start, generation, contextId = 'native-at-probe') {
        return {contextId, generation, selection: start, showCandidateIndex: true,
            candidatePage: {totalCount: 27, position: start + 1,
                previousIndex: start === 0 ? null : start - 9, nextIndex: start >= 18 ? null : start + 9,
                items: Array.from({length: 9}, (_, offset) => ({
                    index: start + offset, text: `試験候補${start + offset + 1}`, reading: 'しけん',
                }))}};
    }
    function queue(button) {
        equal(button.get_accessible().do_action(0), true);
    }
    function finish(error) {
        navigation.actor.destroy();
        report({nativeCally: true, passed: !error, assertions,
            error: error ? `${error.message}\n${error.stack}` : null});
    }
    const cases = [
        ['queued page action is retired before the next page', () => {
            queue(navigation._next);
            navigation.update(snapshot(9, 2), layout);
        }, () => equal(submitted, [])],
        ['current page action runs once', () => queue(navigation._next), () => {
            equal(submitted, [['select', 18, false, 2, 'native-at-probe']]);
            submitted.length = 0;
        }],
        ['queued candidate cannot cross a selection update', () => {
            queue(navigation._rows.get_children()[0]);
            navigation.update({...snapshot(9, 2), selection: 10}, layout);
        }, () => equal(submitted, [])],
        ['queued action cannot cross hide and reopen', () => {
            queue(navigation._next);
            navigation.collapse();
            navigation.expanded = true;
            navigation.update(snapshot(9, 2), layout);
        }, () => equal(submitted, [])],
        ['queued candidate cannot cross an input context', () => {
            queue(navigation._rows.get_children()[0]);
            navigation.update(snapshot(9, 2, 'another-native-at-probe'), layout);
        }, () => equal(submitted, [])],
        ['current candidate runs once', () => {
            queue(navigation._rows.get_children()[0]);
        }, () => equal(submitted, [['select', 9, true, 2, 'another-native-at-probe']])],
    ];
    function waitForPaint(callback) {
        const deadline = GLib.get_monotonic_time() + PAINT_DEADLINE_US;
        const poll = () => {
            const visible = [navigation._next, navigation._rows.get_children()[0]].every(
                button => button.get_accessible().ref_state_set().contains_state(Atk.StateType.SHOWING));
            if (visible) {
                callback();
                return GLib.SOURCE_REMOVE;
            }
            if (GLib.get_monotonic_time() >= deadline) {
                finish(new Error('GNOME did not show the native test actions'));
                return GLib.SOURCE_REMOVE;
            }
            return GLib.SOURCE_CONTINUE;
        };
        if (poll() === GLib.SOURCE_CONTINUE)
            GLib.timeout_add(GLib.PRIORITY_DEFAULT, PAINT_POLL_MS, poll);
    }
    function step() {
        try {
            if (stage) {
                cases[stage - 1][2]();
                assertions.push(cases[stage - 1][0]);
            }
            if (stage === cases.length) {
                finish(null);
                return GLib.SOURCE_REMOVE;
            }
            waitForPaint(() => {
                try {
                    cases[stage++][1]();
                    // Cally enqueues its callback before this idle. Synchronize
                    // with that queue rather than guessing a wall-clock delay.
                    GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, step);
                } catch (error) {
                    finish(error);
                }
            });
        } catch (error) {
            finish(error);
        }
        return GLib.SOURCE_REMOVE;
    }
    layoutManager.addTopChrome(navigation.actor);
    navigation.actor.set_position(12, 36);
    navigation.actor.width = 360;
    navigation.expanded = true;
    navigation.update(snapshot(0, 1), layout);
    navigation.actor.show();
    GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, step);
}
