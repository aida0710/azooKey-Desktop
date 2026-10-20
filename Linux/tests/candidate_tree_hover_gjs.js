import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';
import {Actor, drainActions, loadShellClass} from './gnome_actor_fixture.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}
const bounds = {x: 0, y: 0, width: 1920, height: 1080};
const imports = {
    St: {Button: Actor, BoxLayout: Actor, Label: Actor, ScrollView: Actor, DrawingArea: Actor,
        PolicyType: {NEVER: 0, AUTOMATIC: 1}},
    Clutter: {ActorAlign: {CENTER: 0, START: 1}, EVENT_PROPAGATE: false},
    GLib: {Variant: class { constructor(_signature, values) { this.values = values; } },
        idle_add: () => 1, source_remove() {}},
    Pango: {AttrList: class { insert() {} }, attr_underline_new() {}, Underline: {SINGLE: 0},
        WrapMode: {WORD_CHAR: 0}, EllipsizeMode: {NONE: 0}},
    Main: {layoutManager: {monitors: [bounds], primaryIndex: 0}},
    global: {workspace_manager: {get_active_workspace: () => ({get_work_area_for_monitor: () => bounds})}},
    Extension: class {},
    attachCandidateAction, messages,
    candidatePlacement: () => ({x: 100, y: 100, width: 400, height: 300, treeHeight: 80,
        side: 'below', permitsAlignment: true}),
};
imports.createWrappingLabel = loadShellClass({fileName: 'candidateText.js', imports, className: 'createWrappingLabel'});
const Navigation = loadShellClass({fileName: 'candidateNavigation.js', imports, className: 'CandidateNavigation'});
const Composition = loadShellClass({fileName: 'candidateComposition.js', imports, className: 'CandidateComposition'});
const Detail = loadShellClass({fileName: 'candidateDetail.js', imports, className: 'CandidateDetail'});
const TreeExtension = loadShellClass({fileName: 'extension.js', imports, className: 'AzooKeyTreeExtension'});
const extension = new TreeExtension();
extension._buttons = new Map();
extension._hoveredAction = null;
extension._treeExpanded = true;
extension._popup = new Actor();
extension._canvas = new Actor();
extension._treeScroll = new Actor();
extension._treeScroll.set_child(extension._canvas);
extension._popup.add_child(extension._treeScroll);
extension._theme = {palette: {background: 'white', text: 'black', surface: 'gray', border: 'black',
    selection: 'blue', selectionText: 'white'}};
extension._cursor = {anchor: () => ({location: [100, 100, 0, 20], permitsWordAlignment: false, source: 'synthetic'})};
extension._interfaceSettings = {get_double: () => 1};
extension._details = new Detail({changed: () => extension._render(extension._lastSnapshot), toggleTree() {}});
extension._popup.add_child(extension._details.actor);
extension._layoutDiagnostics = {update() {}, clear() {}};
extension._announcements = {update() {}, reset() {}};
extension._navigation = new Navigation({select: value => extension._call('Select', value), changed() {}, preview: () => extension._refreshDetails()});
extension._composition = new Composition(value => extension._call('Select', value));
extension._popup.add_child(extension._composition.actor);
extension._popup.add_child(extension._navigation.actor);
const submitted = [];
extension._call = (method, variant) => submitted.push([method, ...variant.values]);
const partial = '確定予定: 日本語\n確定する読み: にほんご\n残る読み: にゅうりょく';
const full = '確定予定: 日本語入力\n確定する読み: にほんごにゅうりょく\n全文の注釈';

function snapshot({generation = 2, selection = 1, numbers = true, contextId = 'synthetic-field'} = {}) {
    const candidates = Array.from({length: 27}, (_, index) => ({index, text: index ? '日本語入力' : '日本語',
        commitScope: {consumedReading: index ? 'にほんごにゅうりょく' : 'にほんご',
            remainingReading: index ? '' : 'にゅうりょく'}}));
    const pageStart = Math.floor(selection / 9) * 9;
    const items = candidates.slice(pageStart, pageStart + 9).map(item => ({
        ...item, reading: item.index ? 'ニホンゴニュウリョク' : 'ニホンゴ',
        detailDescription: item.index ? full : partial,
    }));
    return {contextId, generation, selection, inputState: 'selecting',
        focusedNode: null, selectedPath: [], showCandidateIndex: numbers, pageStart,
        columns: [[0], [1]], candidates,
        nodes: [{id: 0, parent: null, text: '日本語', reading: 'ニホンゴ', terminals: [0], previewDescription: full},
            {id: 1, parent: 0, text: '入力', reading: 'ニュウリョク',
                terminals: Array.from({length: 26}, (_, index) => index + 1), previewDescription: full}],
        candidatePage: {totalCount: 27, start: pageStart, position: selection + 1,
            previousIndex: pageStart ? pageStart - 9 : null,
            nextIndex: pageStart >= 18 ? null : pageStart + 9, items}};
}
function hover(button, value) { button.hover = value; button.emit('notify::hover'); }
function showsSelectedDetails() {
    equal(extension._hoveredAction, null);
    equal(extension._details.label.text.includes(full), true);
}
const numberIdentity = JSON.stringify(['select', 0]);
extension._render(snapshot({generation: 1}));
const firstNumber = extension._buttons.get(numberIdentity);
hover(firstNumber, true);
equal(extension._details.label.text, partial);
equal(firstNumber.get_accessible().do_action(), true);
extension._render(snapshot());
drainActions();
equal(submitted, []);
equal(extension._details.label.text, partial);
const replacementNumber = extension._buttons.get(numberIdentity);
equal(firstNumber === replacementNumber, false);
hover(firstNumber, false);
equal(extension._details.label.text, partial);
hover(replacementNumber, false);
showsSelectedDetails();
print('GNOME tree: stationary hover survives selection, old AT/leave are rejected, current leave restores selection PASS');

hover(replacementNumber, true);
extension._render(snapshot({selection: 10}));
equal(extension._buttons.has(numberIdentity), false);
showsSelectedDetails();
extension._render(snapshot());
showsSelectedDetails();
hover(replacementNumber, true);
showsSelectedDetails();
print('GNOME tree: paging away and back does not revive a number preview without new hover PASS');

const currentNumber = extension._buttons.get(numberIdentity);
hover(currentNumber, true);
equal(extension._details.label.text, partial);
extension._render(snapshot({numbers: false}));
showsSelectedDetails();
extension._render(snapshot());
showsSelectedDetails();
hover(extension._buttons.get(numberIdentity), true);
extension._render(snapshot({contextId: 'another-synthetic-field'}));
showsSelectedDetails();
equal(submitted, []);
print('GNOME tree: hidden numbers and changed input contexts retire hover without committing PASS');

// The same product renderer now gives selection and committing distinct controls.
submitted.length = 0;
extension._hideCandidates();
extension._render(snapshot());
equal(extension._navigation.expanded, true);
equal(extension._treeScroll.visible, false);
equal(extension._composition._sentence.text, '日本語入力');
const firstRow = extension._navigation._rows.get_children()[0];
hover(firstRow, true);
equal(extension._composition._sentence.text, '日本語入力');
equal(extension._details.label.text, partial);
firstRow.get_accessible().do_action();
drainActions();
equal(submitted, [['Select', 'select', 0, false, 2, 'synthetic-field']]);
submitted.length = 0;
extension._render(snapshot({selection: 0}));
equal(extension._composition._sentence.text, '日本語');
equal(extension._composition._remaining.text.includes('にゅうりょく'), true);
const confirm = extension._composition._confirm;
confirm.get_accessible().do_action();
confirm.get_accessible().do_action();
drainActions();
equal(submitted, [['Select', 'select', 0, true, 2, 'synthetic-field']]);
confirm.emit('clicked');
equal(submitted.length, 1);
print('GNOME sentence card: hover leaves selection untouched, AT row selects, confirm commits once with remaining reading PASS');

submitted.length = 0;
extension._render(snapshot({selection: 10}));
extension._details.expanded = true;
extension._treeExpanded = true;
extension._render(snapshot({selection: 10}));
const queuedConfirm = extension._composition._confirm;
const queuedRow = extension._navigation._rows.get_children()[0];
queuedConfirm.get_accessible().do_action();
queuedRow.get_accessible().do_action();
hover(queuedRow, true);
extension._suspendCandidates();
equal(extension._popup.visible, false);
equal(extension._navigation.expanded, true);
equal(extension._treeExpanded, true);
equal(extension._details.expanded, true);
equal(extension._navigation.hoveredItem, null);
equal(extension._buttons.size, 0);
extension._render(snapshot({selection: 10, generation: 3}));
drainActions();
equal(submitted, []);
equal(extension._navigation.expanded, true);
equal(extension._navigation._rows.get_children()[0]._selection.values[1], 9);
equal(extension._treeExpanded, true);
equal(extension._details.expanded, true);
equal(extension._navigation.hoveredItem, null);
queuedRow.emit('clicked');
queuedConfirm.emit('clicked');
equal(submitted, []);
print('GNOME Suspend: expanded page/tree/details survive while queued AT, pointer and hover are retired PASS');

extension._navigation.expanded = false;
extension._suspendCandidates();
extension._render(snapshot({generation: 4}));
equal(extension._navigation.expanded, false);
extension._suspendCandidates();
extension._hideCandidates();
extension._render(snapshot({generation: 4}));
equal(extension._navigation.expanded, true);
equal(extension._treeExpanded, false);
equal(extension._details.expanded, false);
extension._treeExpanded = true;
extension._navigation.expanded = false;
extension._suspendCandidates();
extension._render(snapshot({contextId: 'other-field'}));
equal(extension._navigation.expanded, true);
equal(extension._treeExpanded, false);
const changed = snapshot({contextId: 'other-field'});
changed.candidates[0].text = '別の候補';
extension._navigation.expanded = false;
extension._treeExpanded = true;
extension._suspendCandidates();
extension._render(changed);
equal(extension._navigation.expanded, true);
equal(extension._treeExpanded, false);
print('GNOME presentation reset: Hide while suspended, new input context and changed candidates do not inherit preferences PASS');

submitted.length = 0;
const large = snapshot();
const longText = '長い候補👩‍💻é'.repeat(100);
large.candidates[1].text = longText;
large.candidatePage.items[1].text = longText;
extension._render(large);
equal(extension._composition._sentence.text, longText);
equal(extension._composition._sentence.wrap, true);
equal(extension._composition._sentence.ellipsize, 0);
equal(extension._navigation._rows.get_children()[1]._candidateLabel.text, longText);
equal(extension._navigation._rows.get_children()[1]._candidateLabel.wrap, true);
equal(extension._navigation._rows.get_children()[1]._selectionMark.text, '✓');
const selectedBeforeHover = extension._composition._confirm;
hover(extension._navigation._rows.get_children()[0], true);
equal(extension._composition._confirm === selectedBeforeHover, true);
equal(extension._composition._sentence.text, longText);
equal(submitted, []);
print('GNOME readable sentence/list: complete Unicode text is wrapped, selected row is marked and hover never retargets confirm PASS');

submitted.length = 0;
extension._hideCandidates();
const branches = snapshot();
branches.nodes[0].depth = 0;
branches.nodes[1].depth = 1;
branches.nodes.push({id: 2, depth: 1, parent: 0, text: '変換', reading: 'へんかん',
    terminals: [], previewDescription: full});
branches.columns = [[0], [1, 2]];
branches.selectedPath = [0, 1];
branches.focusedNode = 0;
extension._render(branches);
extension._treeExpanded = true;
extension._render(branches);
equal(extension._buttons.has(JSON.stringify(['node', 2])), false);
const secondWord = extension._buttons.get(JSON.stringify(['node', 1]));
secondWord.get_accessible().do_action();
drainActions();
equal(submitted, [['Select', 'node', 1, false, 2, 'synthetic-field']]);
submitted.length = 0;
extension._render({...branches, focusedNode: 1});
equal(extension._buttons.has(JSON.stringify(['node', 2])), true);
extension._buttons.get(JSON.stringify(['node', 2])).get_accessible().do_action();
extension._suspendCandidates();
extension._render({...branches, focusedNode: 1});
drainActions();
equal(submitted, []);
print('GNOME progressive tree: selecting a word reveals its alternatives and Suspend rejects its old AT action PASS');
