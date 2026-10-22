// Run with gjs -m Linux/tests/candidate_announcements_gjs.js and AZOOKEY_BRIDGE set.
import Gio from 'gi://Gio';
import {attachCandidateAction, CandidateAnnouncements} from '../gnome-extension/candidateAccessibility.js';
import {closeCoreBridge, withDisplay} from './core_bridge_gjs.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}

// Core composes each announcement; the renderer speaks it once per context.
const fixture = Gio.File.new_for_uri(import.meta.url).get_parent().get_child('fixtures/candidate_announcements.json');
const snapshot = JSON.parse(new TextDecoder().decode(fixture.load_contents(null)[1]));
const spoken = [];
const announcements = new CandidateAnnouncements(text => spoken.push(text));
const update = changes => announcements.update(withDisplay({...snapshot, ...changes}));
update({});
update({generation: 2, location: [20, 30, 0, 18]});
update({showRelativeScores: true});
equal(spoken, ['変換候補 1 / 2。日本。読み ニホン。語 1 / 2。確定予定 日本に行く']);
update({selection: 1, focusedNode: 11, selectedPath: [11, 13]});
update({focusedNode: 12});
equal(spoken.slice(1), [
    '変換候補 2 / 2。日本。読み ニッポン。語 1 / 2。確定予定 日本に行く',
    '変換候補 1 / 2。に行く。読み ニイク。語 2 / 2。確定予定 日本に行く',
]);
for (const inputState of ['none', 'composing', 'suggesting', 'unknown'])
    update({inputState});
equal(spoken.length, 3);
update({});
update({contextId: 'another-synthetic-field'});
equal(spoken.length, 5);
closeCoreBridge();

// Exercise the action lifecycle; the real Cally/AT-SPI boundary is tested in GNOME.
let action, destroy, clicked = 0;
const accessible = {
    add_action: (name, description, key, callback) => {
        equal(name, 'click');
        action = callback;
        return 1;
    },
    get_object: () => button,
};
const button = {
    reactive: true, mapped: true,
    get_accessible: () => accessible,
    connect: (signal, callback) => { equal(signal, 'destroy'); destroy = callback; },
    is_mapped() { return this.mapped; },
    emit: (signal, number) => { equal([signal, number], ['clicked', 1]); clicked++; },
};
attachCandidateAction(button);
action(accessible);
equal(clicked, 1);
button.mapped = false;
action(accessible);
button.mapped = true;
button.reactive = false;
action(accessible);
equal(clicked, 1);
destroy();
button.reactive = true;
action(accessible);
equal(clicked, 1);
print('GNOME candidate announcements: Core text spoken once per selection and context, non-focusing actions PASS');
