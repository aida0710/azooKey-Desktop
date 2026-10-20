// Exercise dictionary UI and late callbacks with real product code and isolated actors.
import {Actor, ScrollableActor, ScrollViewActor, drainActions, loadShellClass} from './gnome_actor_fixture.js';
import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';
import {candidatePlacement} from '../gnome-extension/candidatePlacement.js';

function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}
function assert(condition, message) { if (!condition) throw new Error(message); }
const external = [];
const pending = [];
const Gio = {AppInfo: {launch_default_for_uri: uri => external.push(uri)},
    DBus: {session: {call: (...arguments_) => pending.push(arguments_)}}, DBusCallFlags: {NONE: 0}};
class MeasuredBox extends ScrollableActor {
    get_preferred_height(width) {
        const heights = this.children.filter(child => child.visible).map(child => child.get_preferred_height(width)[1]);
        const height = this.vertical ? heights.reduce((sum, value) => sum + value, 0) : Math.max(0, ...heights);
        return [height, height];
    }
}
const imports = {Gio, candidatePlacement, St: {Button: Actor, BoxLayout: MeasuredBox, Label: Actor, ScrollView: ScrollViewActor,
    PolicyType: {NEVER: 0, AUTOMATIC: 1}}, Pango: {WrapMode: {WORD_CHAR: 0}, EllipsizeMode: {NONE: 0, END: 1}},
    Clutter: {ActorAlign: {START: 0, CENTER: 1}}, attachCandidateAction, messages,
    GLib: {Variant: class { constructor(signature, values) { this.signature = signature; this.values = values; } }},
    Extension: class {}};
imports.createWrappingLabel = loadShellClass({fileName: 'candidateText.js', imports, className: 'createWrappingLabel'});
const Detail = loadShellClass({fileName: 'candidateDetail.js', imports, className: 'CandidateDetail'});
const detail = new Detail({changed() {}, toggleTree() {}});
const response = {status: 'found', word: '保証', reading: 'ホショウ', readingUnspecified: true,
    senses: [{synset: 'fixture', definitions: ['義務が果たされるという保証'], examples: ['保証を求める'], synonyms: ['確約']}],
    copyright: messages.definitionAttribution};
detail.update({text: '既存の候補詳細'});
detail.setWordDefinitions(response);
detail.layout({identity: 'a', treeExpanded: false, fontSize: 18, width: 360, maximumHeight: 100});
assert(detail._definitionPreview.text.includes('義務が果たされる'), 'Actual short meaning must render');
assert(detail._definitionPreview.is_mapped(), 'The short meaning must have its own visible line');
assert(detail._definitionHeading.text.includes(messages.definitionSourceShort), 'The heading must name the source');
assert(detail._definitionPreview.accessible_name.includes('義務が果たされる'), 'AT must read the current meaning without an AT-SPI Text interface');
assert(detail._definitionFull.accessible_name.includes('保証を求める'), 'AT must read the full definition and examples');
equal(detail._definitionPreview.wrap, false);
equal(detail._definitionHeading.wrap, false);
assert(detail._scrollContent.get_children()[0] === detail._definitionFull &&
    detail._scrollContent.get_children()[1] === detail.label, 'The full meaning must precede candidate metadata');
assert(detail._definitionFull.text.includes('保証を求める') && detail._definitionFull.text.includes('確約'), 'Examples and read-only synonyms must render');
assert(detail._definitionFull.text.includes(messages.definitionReadingNote) && detail._definitionFull.text.includes('NICT'), 'Reading caveat and attribution must render');
equal(external, []);
print('GNOME dictionary rendering: real fields, examples, limited read-only synonyms and source attribution PASS');

const oldSource = detail._definitionSource;
oldSource.get_accessible().do_action();
detail.setWordDefinitions({...response, word: '保障'});
drainActions();
equal(external, []);
detail.expanded = true;
detail.layout({identity: 'a', treeExpanded: false, fontSize: 18, width: 360, maximumHeight: 100});
detail._definitionSource.get_accessible().do_action();
drainActions();
equal(external, ['https://bond-lab.github.io/wnja/index.ja.html']);
detail.actor.hide();
detail._definitionSource.emit('clicked');
equal(external.length, 1);
print('GNOME source link: explicit current action only; retired/hidden actions do not open a browser PASS');


const longResponse = {...response, word: '極めて長い語名'.repeat(80),
    senses: [{definitions: ['語釈'.repeat(300)], examples: ['長文用例'.repeat(300)], synonyms: ['類語'.repeat(40)]}]};
detail.actor.show();
detail.setWordDefinitions(longResponse);
equal(detail.label.text, '既存の候補詳細');
for (const expanded of [false, true]) {
    detail.expanded = expanded;
    const height = detail.layout({identity: 'a', treeExpanded: false, fontSize: 24, width: 200, maximumHeight: 120});
    assert(height <= 120 && detail.actor.height <= 120, 'Long entries must fit the available detail height');
    assert(detail._definitionSource.get_parent() === detail._scrollContent, 'The source action must remain in the scrollable full entry');
    if (!expanded) {
        assert(detail._definitionHeading.visible && detail._definitionPreview.visible, 'Long words must not displace the meaning line');
        equal(detail._definitionHeading.ellipsize, imports.Pango.EllipsizeMode.END);
        equal(detail._definitionPreview.ellipsize, imports.Pango.EllipsizeMode.END);
        assert(detail._definitionPreview.accessible_name.includes('語釈'.repeat(300)), 'Ellipsis must preserve the full source meaning in AT');
        assert(!detail._definitionSource.is_mapped(), 'Folded entries must not expose hidden source controls');
    } else {
        assert(detail._definitionFull.text.includes('長文用例'), 'Expanded entries must retain the full long text');
        assert(detail._scroll.height <= 120 - detail._header.get_preferred_height(200)[1], 'Full entry scrolling must include the header budget');
    }
}
print('GNOME narrow work area: long words/meanings at 24px stay bounded with full entry/source reachable by scrolling PASS');


const measured = new Detail({changed() {}, toggleTree() {}});
measured.setWordDefinitions(response);
// Model a theme whose two text lines exceed the nominal detail budget.
measured._header.get_preferred_height = () => [44, 44];
for (const label of [measured._definitionHeading, measured._definitionPreview])
    label.get_preferred_height = () => [41, 41];
const measuredHeight = measured.layout({identity: 'theme', treeExpanded: false,
    fontSize: 24, width: 200, maximumHeight: 96, availableHeight: 190});
assert(measuredHeight >= 44 + 41 * 2 && measuredHeight <= 190,
    'Actual heading/meaning metrics must be reserved before list space, within the remaining work area');
assert(measured._definitionPreview.is_mapped() && measured._definitionHeading.is_mapped(),
    'Both independent single-line labels must stay visible under a larger theme');
const oneLineHeight = measured.layout({identity: 'theme', treeExpanded: false,
    fontSize: 24, width: 200, maximumHeight: 60, availableHeight: 90});
assert(oneLineHeight <= 90 && measured._definitionPreview.is_mapped() && !measured._definitionHeading.visible,
    'When only one measured line fits, the actual meaning takes priority over the heading');
equal(measured._definitionPreview.accessible_name, `${messages.definitionWord('保証', 'ホショウ')}\n義務が果たされるという保証`);
measured.setWordDefinitions({...response, word: '保障', senses: [{definitions: ['新しい語釈'], examples: [], synonyms: []}]});
assert(measured._definitionPreview.accessible_name.includes('新しい語釈') &&
    !measured._definitionFull.accessible_name.includes('保証を求める'), 'AT names must replace old meanings on target changes');
print('GNOME native regression model: separate single-line meanings, measured theme budget and current/full AT names PASS');

detail._scroll.get_vadjustment().value = 29;
detail.setWordDefinitions(null);
detail.setWordDefinitions({status: 'loading'});
detail.setWordDefinitions(longResponse);
equal(detail._scroll.get_vadjustment().value, 29);
detail.update({text: '別の候補詳細'});
equal(detail._scroll.get_vadjustment().value, 0);
print('GNOME same-candidate dictionary completion/Suspend preserves reading position; a new candidate resets it PASS');

const ExtensionClass = loadShellClass({fileName: 'extension.js', imports, className: 'AzooKeyTreeExtension'});
const extension = new ExtensionClass();
const displayed = [];
const renders = [];
extension._details = {setWordDefinitions: value => displayed.push(value)};
extension._popup = {visible: true};
extension._presentationMode = 'menu';
extension._definitionEpoch = 0;
extension._definitionKey = null;
extension._lastSnapshot = {contextId: 'field', generation: 5, selection: 0, focusedNode: 0};
extension._render = value => renders.push(value);
const snapshotBefore = JSON.stringify(extension._lastSnapshot);
function complete(position, value) {
    const arguments_ = pending[position];
    arguments_.at(-1)({call_finish: () => ({deepUnpack: () => [JSON.stringify(value)]})}, {});
}
extension._lookupWordDefinitions('node', 0);
extension._lookupWordDefinitions('node', 0);
equal(pending.length, 1);
equal(pending[0][3], 'LookupWordDefinitions');
equal(pending[0][4].values, ['field', 5, 'node', 0]);
complete(0, response);
equal(displayed.at(-1).word, '保証');
equal(JSON.stringify(extension._lastSnapshot), snapshotBefore);
equal(renders.length, 1);
print('GNOME asynchronous dictionary: request is separate from selection and candidate identity PASS');

extension._lookupWordDefinitions('node', 1);
extension._clearWordDefinitions();
const afterHide = displayed.length;
complete(1, {...response, word: '保障'});
equal(displayed.length, afterHide);
extension._lookupWordDefinitions('node', 0);
extension._lookupWordDefinitions('candidate', 2);
const beforeOldReply = displayed.length;
complete(2, response);
equal(displayed.length, beforeOldReply);
complete(3, {...response, word: '補償'});
equal(displayed.at(-1).word, '補償');
print('GNOME dictionary lifetime: hide/new target retire old completions without modifying input PASS');

extension._presentationMode = 'live';
extension._lookupWordDefinitions('node', 0);
equal(pending.length, 4);
equal(displayed.at(-1), null);
print('GNOME composing: the branch tree remains compact and starts no dictionary query PASS');


const Composition = loadShellClass({fileName: 'candidateComposition.js', imports, className: 'CandidateComposition'});
const Navigation = loadShellClass({fileName: 'candidateNavigation.js', imports, className: 'CandidateNavigation'});
const palette = {background: '#fff', text: '#000', selection: '#ddd', selectionText: '#000',
    surface: '#fff', border: '#ccc', secondaryText: '#555'};
const budgetSnapshot = {contextId: 'budget', generation: 1, selection: 0, inputState: 'selecting',
    reading: 'ホショウ', showCandidateIndex: true, candidates: [{index: 0, text: '保証'}],
    candidatePage: {start: 0, position: 1, totalCount: 9, previousIndex: null, nextIndex: null,
        items: Array.from({length: 9}, (_, index) => ({index, text: '保証'}))}};
for (const workAreaHeight of [800, 320]) {
    for (const treeExpanded of [false, true]) {
        const card = new ExtensionClass();
        const commits = [];
        card._presentationMode = 'menu';
        card._treeExpanded = treeExpanded;
        card._popup = new Actor();
        card._treeScroll = new Actor();
        card._composition = new Composition(selection => commits.push(selection.values));
        card._navigation = new Navigation({select() {}, changed() {}, preview() {}});
        card._details = new Detail({changed() {}, toggleTree() {}});
        card._details.setWordDefinitions(longResponse);
        // Model a full long entry rather than the fixture actor's short natural height.
        card._details._scrollContent.get_preferred_height = () => [1000, 1000];
        card._refreshDetails = () => {};
        const navigationHeights = [];
        const updateNavigation = card._navigation.update.bind(card._navigation);
        card._navigation.update = (snapshot, options) => {
            const height = updateNavigation(snapshot, options);
            navigationHeights.push(height);
            return height;
        };
        const options = {bounds: {x: 0, y: 0, width: 640, height: workAreaHeight}, fontSize: 24,
            treeContentWidth: 400, treeContentHeight: 600, nodes: new Map(),
            actionIdentity: 'budget', location: [100, 50, 0, 20], palette};
        card._layoutCard(budgetSnapshot, options);
        const confirm = card._composition._confirm;
        const compositionHeight = card._composition.actor.height;
        const compactListHeight = card._navigation._scroll.height;
        const minimumNavigationHeight = navigationHeights[0];
        card._details.expanded = true;
        card._layoutCard(budgetSnapshot, options);
        assert(card._composition._confirm === confirm && confirm.is_mapped() && confirm.reactive,
            'Opening the entry must preserve the current explicit confirm action');
        equal(card._composition.actor.height, compositionHeight);
        assert(card._navigation.actor.height >= minimumNavigationHeight,
            'Expanded details must preserve the page controls and navigation minimum');
        assert(card._navigation._scroll.height < compactListHeight,
            'The sentence list must yield its excess rows to the explicitly opened entry');
        const contentHeight = compositionHeight + card._navigation.actor.height +
            card._details.actor.height + card._treeScroll.height;
        assert(contentHeight <= workAreaHeight && card._popup.height <= workAreaHeight,
            'Expanded details and remaining list/tree must fit the work area');
        if (workAreaHeight === 800) {
            const lineHeight = card._details._definitionPreview.get_preferred_height(560)[1];
            assert(card._details._scroll.height >= lineHeight * 4,
                'A long full entry must show several example lines on a normal desktop');
        }
        equal(commits, []);
        confirm.get_accessible().do_action();
        confirm.get_accessible().do_action();
        drainActions();
        equal(commits, [['select', 0, true, 1, 'budget']]);
    }
}
print('GNOME expanded entry: examples gain readable space at 800px, 320px stays bounded, and composition/page controls/confirm-once survive PASS');


const fractional = new Detail({changed() {}, toggleTree() {}});
fractional.setWordDefinitions(longResponse);
fractional.applyPalette({background: '#fff', text: '#000', border: '#ccc'});
const fractionalHeaderHeight = 44.2;
const fractionalHeadingHeight = 30.4;
const fractionalPreviewHeight = 32.7;
fractional._header.get_preferred_height = () => [fractionalHeaderHeight, fractionalHeaderHeight];
fractional._definitionHeading.get_preferred_height = () => [fractionalHeadingHeight, fractionalHeadingHeight];
fractional._definitionPreview.get_preferred_height = () => [fractionalPreviewHeight, fractionalPreviewHeight];
fractional._scrollContent.get_preferred_height = () => [900.3, 900.3];
const separatorHeight = Number(fractional.actor.style.match(/border-top: ([\d.]+)px/)[1]);
for (const [expanded, maximumHeight, availableHeight] of [
    [true, 345.6, 500.8], [true, 345.6, 160.9], [true, 120.1, 70.9],
    [false, 120.7, 150.8], [false, 120.7, 100.9], [false, 120.7, 70.9],
]) {
    fractional.expanded = expanded;
    const height = fractional.layout({identity: 'fractional', treeExpanded: false,
        fontSize: 24, width: 558, maximumHeight, availableHeight});
    for (const allocation of [height, fractional.actor.height, fractional._scroll.height, fractional._definitionSummary.height])
        assert(Number.isInteger(allocation) && allocation >= 0, 'Every detail allocation must use whole pixels');
    const previewHeight = fractional._definitionSummary.visible ? Math.ceil(fractionalPreviewHeight) +
        (fractional._definitionHeading.visible ? Math.ceil(fractionalHeadingHeight) : 0) : 0;
    const childrenAndBorder = Math.ceil(fractionalHeaderHeight) + separatorHeight +
        Math.ceil(fractional._scroll.height) + previewHeight;
    assert(childrenAndBorder <= height, 'Independently rounded children plus the separator must fit the parent');
    assert(height <= Math.floor(availableHeight), 'The parent must stay inside the remaining work area');
    if (expanded)
        assert(height <= Math.floor(maximumHeight), 'The expanded viewport must stay inside its fractional maximum');
}
print('GNOME fractional theme metrics: rounded child heights and the separator stay within whole-pixel parent/work-area bounds PASS');
