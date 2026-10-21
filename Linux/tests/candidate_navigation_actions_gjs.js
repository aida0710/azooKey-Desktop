// Real navigation code with a model of Cally 46's deferred action delivery.
import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';
import {Actor, ScrollableActor, ScrollViewActor, drainActions, loadShellClass} from './gnome_actor_fixture.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}

// Stub only GNOME actors; all navigation and activation decisions are product code.
const imports = {
    St: {Button: Actor, BoxLayout: ScrollableActor, Label: Actor, ScrollView: ScrollViewActor,
        PolicyType: {NEVER: 0, AUTOMATIC: 1}},
    Clutter: {ActorAlign: {CENTER: 0, START: 1}, EVENT_PROPAGATE: false},
    Pango: {WrapMode: {WORD_CHAR: 0}, EllipsizeMode: {NONE: 0}},
    GLib: {Variant: class { constructor(_signature, values) { this.values = values; } }},
    attachCandidateAction, messages,
};
imports.createWrappingLabel = loadShellClass({fileName: 'candidateText.js', imports, className: 'createWrappingLabel'});
const Navigation = loadShellClass({fileName: 'candidateNavigation.js', className: 'CandidateNavigation', imports});
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
equal(submitted, [['select', 10, false, 2, 'synthetic-field']]);
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

// Walk the existing page targets, including the short final page, without renumbering candidates.
submitted.length = 0;
const many = new Navigation({select: action => submitted.push(action.values), changed() {}, preview() {}});
for (let start = 0; start < 500; start += 9) {
    const page = snapshot(start, 8);
    page.candidatePage = {totalCount: 500, position: start + 1,
        previousIndex: start ? start - 9 : null, nextIndex: start + 9 < 500 ? start + 9 : null,
        items: Array.from({length: Math.min(9, 500 - start)}, (_, offset) => ({index: start + offset,
            text: `候補${start + offset + 1}`, reading: 'ご'}))};
    many.update(page, layout);
    equal(many._previous.reactive, start > 0);
    equal(many._next.reactive, start + 9 < 500);
    if (start + 9 < 500) {
        many._next.get_accessible().do_action();
        drainActions();
        equal(submitted.pop(), ['select', start + 9, false, 8, 'synthetic-field']);
    }
}
equal(many._rows.get_children().length, 5);
many._rows.get_children()[4].get_accessible().do_action();
drainActions();
equal(submitted, [['select', 499, false, 8, 'synthetic-field']]);
print('GNOME full list: 500 candidates remain reachable and the short final page selects actual index 499 PASS');

const reveal = new Navigation({select() {}, changed() {}, preview() {}});
reveal.update({...snapshot(0, 1), selection: 5}, layout);
const selectedRow = reveal._rows.get_children()[5];
selectedRow.y = 300;
selectedRow.height = 40;
const scroll = reveal._scroll.get_vadjustment();
scroll.value = 0;
scroll.page_size = 100;
scroll.upper = 600;
selectedRow.emit('notify::allocation');
equal(scroll.value, 240);
scroll.value = 50;
selectedRow.emit('notify::allocation');
equal(scroll.value, 50);
reveal.update({...snapshot(0, 1), selection: 6}, layout);
const longRow = reveal._rows.get_children()[6];
longRow.y = 400;
longRow.height = 150;
longRow.emit('notify::allocation');
equal(scroll.value, 400);
print('GNOME selected row: allocation reveals keyboard selection once, preserves manual scrolling and shows the start of long rows PASS');

const compact = new Navigation({select: action => submitted.push(action.values), changed() {}, preview() {}, compact: true});
const lastSelected = {...snapshot(0, 4), selection: 8};
lastSelected.candidatePage.position = 9;
compact.update(lastSelected, layout);
const unchangedRows = compact._rows.get_children();
for (const [index, row] of unchangedRows.entries()) {
    row.y = index * 36;
    row.height = 36;
}
const compactScroll = compact._scroll.get_vadjustment();
compactScroll.upper = 9 * 36;
for (const visibleRows of [9, 7, 5]) {
    compactScroll.page_size = visibleRows * 36;
    compact.update({...lastSelected, candidateVisibleRows: visibleRows}, {...layout, listHeight: visibleRows * 36});
    equal(compact.visibleRows, visibleRows);
    equal(compact._rows.get_children().every((row, index) => row === unchangedRows[index]), true);
    equal(compact._rows.get_children().length, 9);
    equal(compactScroll.value + compactScroll.page_size, 9 * 36);
}
for (const invalid of [undefined, true, '9', 6, 100]) {
    compact.update({...lastSelected, candidateVisibleRows: invalid}, layout);
    equal(compact.visibleRows, 7);
}
submitted.length = 0;
compact._rows.get_children()[8].get_accessible().do_action();
drainActions();
equal(submitted, [['select', 8, false, 4, 'synthetic-field']]);
compactScroll.value = 0;
compact._viewportHeight = 9 * 36;
compactScroll.page_size = 5 * 36;
compact._viewportChanged();
equal(compactScroll.value, 4 * 36);
compactScroll.value = 0;
compactScroll.page_size = 4 * 36;
compact._viewportChanged();
equal(compactScroll.value, 0);
print('GNOME configurable rows: five/seven/nine preserve the nine real entries and reveal the selected last entry after shrinking PASS');

const shortRows = new Navigation({select() {}, changed() {}, preview() {}, compact: true});
shortRows.update(snapshot(0, 1), layout);
for (const row of shortRows._rows.get_children()) row.get_preferred_height = () => [30, 33];
shortRows._rows.get_children()[0].get_preferred_height = () => [60, 63];
for (const count of [5, 7, 9]) {
    shortRows.update({...snapshot(0, 1), candidateVisibleRows: count}, {...layout, listHeight: count * 33});
    equal(shortRows._scroll.height, count * 30);
    equal(shortRows._rows.get_children().length, 9);
}
shortRows.update({...snapshot(0, 1), candidateVisibleRows: 7}, {...layout, listHeight: 100});
equal(shortRows._scroll.height, 100);
print('GNOME row count: short real rows stop at the chosen count while a smaller screen still limits the viewport PASS');
