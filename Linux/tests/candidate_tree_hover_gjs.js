import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';
import {Actor, ScrollableActor, ScrollViewActor, drainActions, loadShellClass} from './gnome_actor_fixture.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}
const bounds = {x: 0, y: 0, width: 1920, height: 1080};
const pendingReveals = new Map();
let nextReveal = 1;
function drainReveals() {
    for (const [identity, reveal] of pendingReveals) {
        pendingReveals.delete(identity);
        reveal();
    }
}
// Supply scalable font metrics without claiming a native Pango/St measurement.
class MeasuredLabelActor extends Actor {
    get_preferred_height() {
        const fontSize = Number(this.style?.match(/font-size: ([\d.]+)px/)?.[1] ?? 18);
        const height = Math.ceil(fontSize * 1.2);
        return [height, height];
    }
}
const imports = {
    St: {Button: Actor, BoxLayout: ScrollableActor, Label: MeasuredLabelActor, ScrollView: ScrollViewActor, DrawingArea: Actor,
        PolicyType: {NEVER: 0, AUTOMATIC: 1}},
    Clutter: {ActorAlign: {CENTER: 0, START: 1}, EVENT_PROPAGATE: false},
    GLib: {Variant: class { constructor(_signature, values) { this.values = values; } },
        idle_add: (_priority, reveal) => { const identity = nextReveal++; pendingReveals.set(identity, reveal); return identity; },
        source_remove: identity => pendingReveals.delete(identity)},
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
extension._treeScroll = new ScrollViewActor();
extension._content = new ScrollableActor();
extension._content.add_child(extension._canvas);
extension._treeScroll.set_child(extension._content);
extension._popup.add_child(extension._treeScroll);
extension._theme = {palette: {background: 'white', text: 'black', surface: 'gray', border: 'black',
    selection: 'blue', selectionText: 'white'}};
extension._cursor = {anchor: () => ({location: [100, 100, 0, 20], permitsWordAlignment: false, source: 'synthetic'})};
extension._interfaceSettings = {get_double: () => 1};
extension._details = new Detail({changed: () => extension._render(extension._lastSnapshot),
    toggleTree: () => { extension._treeExpanded = !extension._treeExpanded; extension._render(extension._lastSnapshot); }});
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
        focusedNode: 1, selectedPath: [], showCandidateIndex: numbers, pageStart,
        columns: [[0], [1]], candidates,
        nodes: [{id: 0, depth: 0, parent: null, text: '日本語', reading: 'ニホンゴ', terminals: [0],
                preview: {candidateIndex: selection}, previewDescription: selection ? full : partial},
            {id: 1, depth: 1, parent: 0, text: '入力', reading: 'ニュウリョク',
                terminals: Array.from({length: 26}, (_, index) => index + 1),
                preview: {candidateIndex: selection || 1}, previewDescription: full}],
        candidatePage: {totalCount: 27, start: pageStart, position: selection + 1,
            previousIndex: pageStart ? pageStart - 9 : null,
            nextIndex: pageStart >= 18 ? null : pageStart + 9, items}};
}
function hover(button, value) { button.hover = value; button.emit('notify::hover'); }
function showsSelectedDetails() {
    equal(extension._hoveredAction, null);
    equal(extension._details.label.text.includes(full), true);
}
const nodeIdentity = JSON.stringify(['node', 0]);
extension._render(snapshot({generation: 1}));
extension._treeExpanded = true;
extension._render(snapshot({generation: 1}));
const firstNode = extension._buttons.get(nodeIdentity);
hover(firstNode, true);
equal(extension._details.label.text.startsWith('日本語\n'), true);
equal(firstNode.get_accessible().do_action(), true);
extension._render(snapshot());
drainActions();
equal(submitted, []);
equal(extension._details.label.text.startsWith('日本語\n'), true);
const replacementNode = extension._buttons.get(nodeIdentity);
equal(firstNode === replacementNode, false);
hover(firstNode, false);
equal(extension._details.label.text.startsWith('日本語\n'), true);
hover(replacementNode, false);
showsSelectedDetails();
print('GNOME tree: stationary hover survives selection, old AT/leave are rejected, current leave restores selection PASS');

hover(replacementNode, true);
extension._render(snapshot({selection: 10}));
equal(extension._buttons.get(nodeIdentity)._numberBadge.text, '2');
equal(extension._details.label.text.startsWith('日本語\n'), true);
extension._render(snapshot());
const numberedNode = extension._buttons.get(nodeIdentity);
equal(numberedNode._numberBadge.text, '2');
equal(numberedNode._numberBadge.reactive, false);
equal(numberedNode._numberBadge.can_focus, false);
equal(numberedNode.height >= 44, true);
equal(numberedNode.accessible_name.includes(messages.numberBadge(2)), true);
equal([...extension._buttons.keys()].some(identity => JSON.parse(identity)[0] === 'select'), false);
numberedNode.get_accessible().do_action();
drainActions();
equal(submitted.pop(), ['Select', 'node', 0, false, 2, 'synthetic-field']);
extension._render(snapshot({numbers: false}));
equal(extension._buttons.get(nodeIdentity)._numberBadge, null);
extension._render(snapshot());
hover(extension._buttons.get(nodeIdentity), true);
extension._render(snapshot({contextId: 'another-synthetic-field'}));
showsSelectedDetails();
equal(submitted, []);
print('GNOME block numbers: real page badges share the 44px node action; paging/settings do not invent numbers or separate targets PASS');

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
drainReveals();
const navigationScroll = extension._navigation._scroll.get_vadjustment();
const beforeSuspendRow = extension._navigation._rows.get_children()[1];
beforeSuspendRow.y = 100;
beforeSuspendRow.height = 44;
beforeSuspendRow.emit('notify::allocation');
navigationScroll.value = 37;
extension._treeScroll.get_vadjustment().value = 83;
extension._details._scroll.get_vadjustment().value = 29;
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
equal(extension._navigation._scroll.get_vadjustment().value, 37);
equal(extension._navigation._revealPending, false);
equal(extension._treeScroll.get_vadjustment().value, 83);
// Retiring the hovered partial preview restores different selected-word content.
equal(extension._details._scroll.get_vadjustment().value, 0);
equal(pendingReveals.size, 0);
queuedRow.emit('clicked');
queuedConfirm.emit('clicked');
equal(submitted, []);
extension._details._scroll.get_vadjustment().value = 29;
extension._render(snapshot({selection: 10, generation: 3}));
extension._suspendCandidates();
extension._render(snapshot({selection: 10, generation: 4}));
equal(extension._details._scroll.get_vadjustment().value, 29);
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

extension._hideCandidates();
const liveBranches = {...branches, inputState: 'composing', showCandidateIndex: false, focusedNode: 0};
extension._render(liveBranches);
equal(extension._treeScroll.visible, true);
equal(extension._buttons.has(JSON.stringify(['node', 2])), true);
equal(extension._buttons.get(JSON.stringify(['node', 2]))._numberBadge, null);
equal(extension._navigation.actor.visible, false);
equal(extension._composition.actor.visible, false);
equal(extension._details.actor.visible, false);
drainReveals();
extension._treeScroll.get_vadjustment().value = 67;
extension._render({...liveBranches, generation: 3});
equal(pendingReveals.size, 0);
equal(extension._treeScroll.get_vadjustment().value, 67);
extension._suspendCandidates();
extension._render({...liveBranches, generation: 4});
equal(extension._treeScroll.get_vadjustment().value, 67);
equal(pendingReveals.size, 0);
const liveAlternative = extension._buttons.get(JSON.stringify(['node', 2]));
liveAlternative.get_accessible().do_action();
drainActions();
equal(submitted.pop(), ['Select', 'node', 2, false, 4, 'synthetic-field']);
liveAlternative.get_accessible().do_action();
extension._render({...liveBranches, inputState: 'previewing', generation: 4});
drainActions();
equal(submitted, []);
equal(extension._treeScroll.visible, false);
equal(extension._navigation.expanded, true);
equal(extension._composition.actor.visible, true);
equal(extension._navigation.actor.visible, true);
equal(extension._details.expanded, false);
extension._details._tree.get_accessible().do_action();
drainActions();
equal(extension._treeScroll.visible, true);
equal(extension._buttons.has(JSON.stringify(['node', 2])), false);
extension._navigation.expanded = false;
extension._details.expanded = true;
extension._render({...liveBranches, inputState: 'selecting', generation: 5});
equal(extension._navigation.expanded, false);
equal(extension._treeScroll.visible, true);
equal(extension._details.expanded, true);
const oldTreeToggle = extension._details._tree;
oldTreeToggle.get_accessible().do_action();
extension._render({...liveBranches, generation: 5});
drainActions();
equal(extension._treeScroll.visible, true);
equal(extension._navigation.actor.visible, false);
equal(extension._details.actor.visible, false);
equal(extension._buttons.has(JSON.stringify(['node', 2])), true);
equal(submitted, []);
print('GNOME live branches: alternatives remain visible, redraw/Suspend preserve scroll, and conversion replaces tree with an explicit menu PASS');

for (const scale of [1, 2]) {
    extension._interfaceSettings = {get_double: () => scale};
    extension._render({...liveBranches, candidateTextSize: 'large'});
    const scaledNode = extension._buttons.get(nodeIdentity);
    const caption = scaledNode.get_children().at(-1).get_children()[0];
    const textHeight = caption.get_preferred_height(-1)[1];
    const badgeHeight = scaledNode._numberBadge.get_preferred_height(-1)[1];
    equal(caption.style.includes(`font-size: ${24 * scale}px`), true);
    equal(scaledNode.height, Math.max(44, textHeight + badgeHeight + 4));
    equal(scaledNode.height >= textHeight + badgeHeight + 4, true);
}
extension._interfaceSettings = {get_double: () => 1};
print('GNOME enlarged block: 24px at 100%/200% reserves measured sentence, number badge and both borders without a fixed-height clip PASS');

submitted.length = 0;
extension._hideCandidates();
const sharedWord = {...snapshot({selection: 1, numbers: false}), inputState: 'composing'};
extension._render(sharedWord);
const sharedNode = extension._buttons.get(nodeIdentity);
equal(sharedWord.nodes[0].terminals, [0]);
equal(sharedWord.nodes[0].preview.candidateIndex, 1);
equal(sharedNode._numberBadge.text, '2');
equal(sharedNode.accessible_name.includes(messages.numberBadge(2)), true);
sharedNode.get_accessible().do_action();
drainActions();
equal(submitted, [['Select', 'node', 0, false, 2, 'synthetic-field']]);
equal(extension._navigation.actor.visible, false);
equal([...extension._buttons.keys()].every(identity => JSON.parse(identity)[0] === 'node'), true);
for (const inputState of ['previewing', 'replaceSuggestion']) {
    extension._render({...sharedWord, inputState});
    extension._treeExpanded = true;
    extension._render({...sharedWord, inputState});
    equal(extension._buttons.get(nodeIdentity)._numberBadge, null);
}
const outsidePage = snapshot({selection: 10});
outsidePage.nodes[0].preview.candidateIndex = 0;
extension._render({...outsidePage, inputState: 'composing', showCandidateIndex: false});
equal(extension._buttons.get(nodeIdentity)._numberBadge, null);
for (const preview of [null, {}, {candidateIndex: '1'}, {candidateIndex: -1}, {candidateIndex: 1.5}]) {
    const unavailable = {...sharedWord, nodes: sharedWord.nodes.map(node => node.id === 0 ? {...node, preview} : node)};
    extension._render(unavailable);
    equal(extension._buttons.get(nodeIdentity)._numberBadge, null);
}
const unavailableCandidate = {...sharedWord, pageStart: 999,
    nodes: sharedWord.nodes.map(node => node.id === 0 ? {...node, preview: {candidateIndex: 999}} : node)};
extension._render(unavailableCandidate);
equal(extension._buttons.get(nodeIdentity)._numberBadge, null);
print('GNOME reference numbers: shared partial word shows preferred preview 2; live permits no numeric action, AI/previewing and unavailable previews stay unnumbered PASS');

submitted.length = 0;
extension._hideCandidates();
const composing = {...snapshot({selection: 0, numbers: false}), inputState: 'composing', preedit: 'にほんご', reading: 'にほんご'};
extension._render(composing);
equal(extension._composition.actor.visible, false);
equal(extension._composition._confirm, null);
equal(extension._navigation.actor.visible, false);
equal(extension._details.actor.visible, false);
equal(extension._treeScroll.visible, true);
const composingNode = extension._buttons.get(nodeIdentity);
composingNode.get_accessible().do_action();
extension._render({...composing, inputState: 'selecting'});
drainActions();
equal(submitted, []);
equal(extension._composition._title.text, messages.composition);
equal(extension._composition._confirm.label, `${messages.submit} ↵`);
const selectedConfirm = extension._composition._confirm;
selectedConfirm.get_accessible().do_action();
extension._render(composing);
drainActions();
equal(submitted, []);
equal(extension._composition._confirm, null);
for (const inputState of ['previewing', 'replaceSuggestion']) {
    extension._render({...composing, inputState});
    equal(extension._composition.actor.visible, true);
    equal(extension._navigation.actor.visible, true);
    equal(extension._treeScroll.visible, false);
    equal(extension._composition._title.text, messages.composition);
    equal(extension._composition._confirm.label, `${messages.submit} ↵`);
}
print('GNOME input modes: live input shows only tree; conversion states show the menu and retire old actions on each transition PASS');

submitted.length = 0;
const unselectedMenu = {...composing, candidateDisplayMode: 'menu',
    candidatePage: {...composing.candidatePage}};
delete unselectedMenu.selection;
delete unselectedMenu.focusedNode;
delete unselectedMenu.candidatePage.position;
extension._render(unselectedMenu);
equal(extension._composition.actor.visible, true);
equal(extension._navigation.actor.visible, true);
equal(extension._treeScroll.visible, false);
equal(extension._lastSnapshot.inputState, 'composing');
equal(extension._lastSnapshot.selection, undefined);
equal(extension._composition._sentence.text, 'にほんご');
equal(extension._composition._confirm, null);
equal(submitted, []);
extension._treeExpanded = true;
extension._render(unselectedMenu);
equal(extension._buttons.get(nodeIdentity)._numberBadge, null);
equal(submitted, []);
print('GNOME reading arrival: explicit menu keeps the formal reading unselected without number-key or Enter candidate claims PASS');

submitted.length = 0;
const longPartial = snapshot({selection: 0, generation: 5});
longPartial.candidates[0].text = longText;
longPartial.candidatePage.items[0].text = longText;
extension._render(longPartial);
const composition = extension._composition;
equal(composition._remainingContent instanceof ScrollableActor, true);
equal(composition._remaining.get_parent() === composition._remainingContent, true);
equal(composition._remainingContent.get_parent() === composition._remainingScroll, true);
equal(composition._content.get_children().includes(composition._remaining), false);
equal(composition._remainingScroll.visible, true);
equal(composition._remainingScroll.height > 0, true);
equal(composition._remaining.text.includes('にゅうりょく'), true);
composition._scroll.get_vadjustment().value = 300;
equal(composition._remainingScroll.get_vadjustment().value, 0);
equal(composition._remainingScroll.visible, true);
equal(composition._scroll.height + composition._remainingScroll.height < composition.actor.height, true);
composition._remainingScroll.get_vadjustment().value = 50;
extension._render(longPartial);
equal(composition._remainingScroll.get_vadjustment().value, 50);
longPartial.candidates[0].commitScope.remainingReading = 'つづき';
extension._render(longPartial);
equal(composition._remainingScroll.get_vadjustment().value, 0);
equal(composition._remaining.text.includes('つづき'), true);
equal(submitted, []);
print('GNOME long partial proposal: remaining reading has a separate bounded viewport and sentence scrolling never hides its region PASS');
