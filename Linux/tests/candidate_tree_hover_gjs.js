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
    Pango: {AttrList: class { insert() {} }, attr_underline_new() {}, Underline: {SINGLE: 0}},
    Main: {layoutManager: {monitors: [bounds], primaryIndex: 0}},
    global: {workspace_manager: {get_active_workspace: () => ({get_work_area_for_monitor: () => bounds})}},
    Extension: class {},
    attachCandidateAction, messages,
    candidatePlacement: () => ({x: 100, y: 100, width: 400, height: 300, treeHeight: 80,
        side: 'below', permitsAlignment: true}),
};
const Navigation = loadShellClass({fileName: 'candidateNavigation.js', imports, className: 'CandidateNavigation'});
const TreeExtension = loadShellClass({fileName: 'extension.js', imports, className: 'AzooKeyTreeExtension'});
const extension = new TreeExtension();
extension._buttons = new Map();
extension._hoveredAction = null;
extension._popup = new Actor();
extension._canvas = new Actor();
extension._popup.add_child(extension._canvas);
extension._treeScroll = new Actor();
extension._theme = {palette: {background: 'white', text: 'black', surface: 'gray', border: 'black',
    selection: 'blue', selectionText: 'white'}};
extension._cursor = {anchor: () => ({location: [100, 100, 0, 20], permitsWordAlignment: false, source: 'synthetic'})};
extension._interfaceSettings = {get_double: () => 1};
extension._details = {actor: new Actor(), applyPalette() {}, update(value) { this.text = value.text; }};
extension._layoutDiagnostics = {update() {}, clear() {}};
extension._announcements = {update() {}, reset() {}};
extension._navigation = new Navigation({select() {}, changed() {}, preview: () => extension._refreshDetails()});
extension._popup.add_child(extension._navigation.actor);
const submitted = [];
extension._call = (method, variant) => submitted.push([method, ...variant.values]);
const partial = '確定予定: 日本語\n確定する読み: にほんご\n残る読み: にゅうりょく';
const full = '確定予定: 日本語入力\n確定する読み: にほんごにゅうりょく\n全文の注釈';

function snapshot({generation = 2, selection = 1, numbers = true, contextId = 'synthetic-field'} = {}) {
    const candidates = Array.from({length: 27}, (_, index) => ({index, text: index ? '日本語入力' : '日本語'}));
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
    equal(extension._details.text.includes(full), true);
}
const numberIdentity = JSON.stringify(['select', 0]);
extension._render(snapshot({generation: 1}));
const firstNumber = extension._buttons.get(numberIdentity);
hover(firstNumber, true);
equal(extension._details.text, partial);
equal(firstNumber.get_accessible().do_action(), true);
extension._render(snapshot());
drainActions();
equal(submitted, []);
equal(extension._details.text, partial);
const replacementNumber = extension._buttons.get(numberIdentity);
equal(firstNumber === replacementNumber, false);
hover(firstNumber, false);
equal(extension._details.text, partial);
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
equal(extension._details.text, partial);
extension._render(snapshot({numbers: false}));
showsSelectedDetails();
extension._render(snapshot());
showsSelectedDetails();
hover(extension._buttons.get(numberIdentity), true);
extension._render(snapshot({contextId: 'another-synthetic-field'}));
showsSelectedDetails();
equal(submitted, []);
print('GNOME tree: hidden numbers and changed input contexts retire hover without committing PASS');
