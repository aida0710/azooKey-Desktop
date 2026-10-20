// Exercise dictionary UI and late callbacks with real product code and isolated actors.
import {Actor, ScrollableActor, ScrollViewActor, drainActions, loadShellClass} from './gnome_actor_fixture.js';
import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';

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
const imports = {Gio, St: {Button: Actor, BoxLayout: MeasuredBox, Label: Actor, ScrollView: ScrollViewActor,
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
