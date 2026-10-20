// Real navigation code with a model of Cally 46's deferred action delivery.
import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';
import {Actor, drainActions, loadShellClass} from './gnome_actor_fixture.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}

// Stub only GNOME actors; all navigation and activation decisions are product code.
const Navigation = loadShellClass({fileName: 'candidateNavigation.js', className: 'CandidateNavigation',
    imports: {
        St: {Button: Actor, BoxLayout: Actor, Label: Actor, ScrollView: Actor, PolicyType: {NEVER: 0, AUTOMATIC: 1}},
        Clutter: {ActorAlign: {CENTER: 0, START: 1}, EVENT_PROPAGATE: false},
        GLib: {Variant: class { constructor(_signature, values) { this.values = values; } }},
        attachCandidateAction, messages,
    },
});
function snapshot(start, generation, contextId = 'synthetic-field') {
    return {contextId, generation, selection: start, showCandidateIndex: true,
        candidatePage: {totalCount: 27, position: start + 1,
            previousIndex: start === 0 ? null : start - 9, nextIndex: start >= 18 ? null : start + 9,
            items: Array.from({length: 9}, (_, offset) => ({
                index: start + offset, text: `候補${start + offset + 1}`, reading: 'ご',
            }))}};
}
const submitted = [];
const navigation = new Navigation({select: action => submitted.push(action.values), changed() {}, preview() {}});
const layout = {fontSize: 18, listHeight: 200};
navigation.expanded = true;
navigation.update(snapshot(0, 1), layout);
const previousNext = navigation._next;
equal(previousNext.get_accessible().do_action(0), true);
navigation.update(snapshot(9, 2), layout);
drainActions();
equal(submitted, []);
navigation._next.get_accessible().do_action(0);
drainActions();
equal(submitted, [['select', 18, false, 2, 'synthetic-field']]);
submitted.length = 0;

navigation._rows.get_children()[0].get_accessible().do_action(0);
navigation.update({...snapshot(9, 2), selection: 10}, layout);
drainActions();
equal(submitted, []);
navigation._rows.get_children()[1].get_accessible().do_action(0);
drainActions();
equal(submitted, [['select', 10, true, 2, 'synthetic-field']]);
submitted.length = 0;

navigation._next.get_accessible().do_action(0);
navigation.collapse();
navigation.expanded = true;
navigation.update(snapshot(9, 2), layout);
drainActions();
equal(submitted, []);
navigation._rows.get_children()[0].get_accessible().do_action(0);
navigation.update(snapshot(9, 2, 'another-synthetic-field'), layout);
drainActions();
equal(submitted, []);
navigation._rows.get_children()[0].get_accessible().do_action(0);
navigation.actor.hide();
drainActions();
equal(submitted, []);
print('GNOME deferred AT actions: page/selection/context update and hide/reopen reject old requests PASS');

const previews = [];
const hoveredNavigation = new Navigation({
    select: action => submitted.push(action.values), changed() {}, preview: item => previews.push(item?.index ?? null),
});
hoveredNavigation.expanded = true;
hoveredNavigation.update(snapshot(0, 1), layout);
const oldHoveredRow = hoveredNavigation._rows.get_children()[0];
oldHoveredRow.hover = true;
oldHoveredRow.emit('notify::hover');
equal(previews, [0]);
oldHoveredRow.get_accessible().do_action(0);
hoveredNavigation.update({...snapshot(0, 2), selection: 2}, layout);
drainActions();
equal(submitted, []);
equal(hoveredNavigation.hoveredItem.index, 0);
equal(previews, [0]);
const currentHoveredRow = hoveredNavigation._rows.get_children()[0];
equal(currentHoveredRow === oldHoveredRow, false);
oldHoveredRow.emit('notify::hover');
equal(hoveredNavigation.hoveredItem.index, 0);
currentHoveredRow.hover = false;
currentHoveredRow.emit('notify::hover');
equal(previews, [0, null]);
currentHoveredRow.hover = true;
currentHoveredRow.emit('notify::hover');
hoveredNavigation.update(snapshot(9, 3), layout);
equal(hoveredNavigation.hoveredItem, null);
// A previous page may return with the same identity; its retired controls still have no authority.
hoveredNavigation.update(snapshot(0, 1), layout);
oldHoveredRow.hover = true;
oldHoveredRow.emit('notify::hover');
equal(hoveredNavigation.hoveredItem, null);
const reopenedRow = hoveredNavigation._rows.get_children()[0];
reopenedRow.hover = true;
reopenedRow.emit('notify::hover');
hoveredNavigation.collapse();
equal(hoveredNavigation.hoveredItem, null);
reopenedRow.emit('notify::hover');
equal(hoveredNavigation.hoveredItem, null);
print('GNOME stationary hover: selection preserves the candidate, leave/page/collapse retire the preview PASS');
