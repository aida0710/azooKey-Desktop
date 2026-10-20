// Real navigation code with a model of Cally 46's deferred action delivery.
import Gio from 'gi://Gio';
import {attachCandidateAction} from '../gnome-extension/candidateAccessibility.js';
import {messages} from '../gnome-extension/candidateMessages.js';

const pending = [];
function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected))
        throw new Error(`${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}
function drain() {
    while (pending.length) pending.shift()();
}

class Actor {
    constructor(properties = {}) {
        Object.assign(this, {visible: true, reactive: true}, properties);
        this.children = [];
        this.signals = new Map();
        this.accessible = {
            add_action: (_name, _description, _key, callback) => {
                this.action = () => callback(this.accessible);
                return 1;
            },
            get_object: () => this,
            do_action: () => {
                if (!this.is_mapped() || !this.reactive) return false;
                pending.push(this.action);
                return true;
            },
        };
    }
    connect(signal, callback) {
        const callbacks = this.signals.get(signal) ?? [];
        callbacks.push(callback);
        this.signals.set(signal, callbacks);
    }
    connect_after(signal, callback) { this.connect(signal, callback); }
    emit(signal, ...args) {
        for (const callback of this.signals.get(signal) ?? []) callback(this, ...args);
    }
    get_accessible() { return this.accessible; }
    is_mapped() { return this.visible && (!this.parent || this.parent.is_mapped()); }
    get_parent() { return this.parent; }
    get_children() { return this.children; }
    add_child(child) { this.children.push(child); child.parent = this; }
    set_child(child) { this.add_child(child); }
    set_width(width) { this.width = width; }
    set_checked(checked) { this.checked = checked; }
    hide() { this.visible = false; }
    destroy() {
        this.visible = false;
        this.emit('destroy');
        if (this.parent) this.parent.children = this.parent.children.filter(child => child !== this);
        this.parent = null;
    }
    destroy_all_children() { for (const child of [...this.children]) child.destroy(); }
}

const file = Gio.File.new_for_uri(import.meta.url).get_parent().get_parent()
    .get_child('gnome-extension/candidateNavigation.js');
// Stub only GNOME actors; all navigation and activation decisions are product code.
const source = new TextDecoder().decode(file.load_contents(null)[1])
    .replace(/^import .*;\n/gm, '').replace(/^export /gm, '');
const Navigation = new Function('St', 'Clutter', 'GLib', 'attachCandidateAction', 'messages',
    source + '\nreturn CandidateNavigation;')(
    {Button: Actor, BoxLayout: Actor, Label: Actor, ScrollView: Actor, PolicyType: {NEVER: 0, AUTOMATIC: 1}},
    {ActorAlign: {CENTER: 0, START: 1}, EVENT_PROPAGATE: false},
    {Variant: class { constructor(_signature, values) { this.values = values; } }},
    attachCandidateAction, messages,
);
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
drain();
equal(submitted, []);
navigation._next.get_accessible().do_action(0);
drain();
equal(submitted, [['select', 18, false, 2, 'synthetic-field']]);
submitted.length = 0;

navigation._rows.get_children()[0].get_accessible().do_action(0);
navigation.update({...snapshot(9, 2), selection: 10}, layout);
drain();
equal(submitted, []);
navigation._rows.get_children()[1].get_accessible().do_action(0);
drain();
equal(submitted, [['select', 10, true, 2, 'synthetic-field']]);
submitted.length = 0;

navigation._next.get_accessible().do_action(0);
navigation.collapse();
navigation.expanded = true;
navigation.update(snapshot(9, 2), layout);
drain();
equal(submitted, []);
navigation._rows.get_children()[0].get_accessible().do_action(0);
navigation.update(snapshot(9, 2, 'another-synthetic-field'), layout);
drain();
equal(submitted, []);
navigation._rows.get_children()[0].get_accessible().do_action(0);
navigation.actor.hide();
drain();
equal(submitted, []);
print('GNOME deferred AT actions: page/selection/context update and hide/reopen reject old requests PASS');
