'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { shouldRunChecks } = require('../ci/should-run-checks.cjs');

const headSHA = 'a'.repeat(40);
const pushContext = {
    eventName: 'push', ref: 'refs/heads/codex/topic', sha: headSHA,
    repo: { owner: 'example', repo: 'input-method' }
};

function pullRequest(overrides = {}) {
    return {
        number: 42, state: 'open', mergeable: true,
        head: { repo: { full_name: 'example/input-method' }, ref: 'codex/topic', sha: headSHA },
        ...overrides
    };
}

function client({ listed = [], current, listError, getError } = {}) {
    const calls = [];
    const github = {
        paginate: async (_endpoint, parameters) => {
            calls.push({ operation: 'list', parameters });
            if (listError) { throw listError; }
            return listed;
        },
        rest: { pulls: {
            list: () => {},
            get: async parameters => {
                calls.push({ operation: 'get', parameters });
                if (getError) { throw getError; }
                return { data: current ?? listed.find(item => item.number === parameters.pull_number) };
            }
        } }
    };
    return { github, calls };
}

async function decision(options = {}, context = pushContext) {
    const { github, calls } = client(options);
    const warnings = [];
    const messages = [];
    const run = await shouldRunChecks({
        github, context, warning: text => warnings.push(text), info: text => messages.push(text)
    });
    return { run, calls, warnings, messages };
}

test('a push without an open PR runs all checks', async () => {
    const outcome = await decision();
    assert.equal(outcome.run, true);
    assert.deepEqual(outcome.calls, [{
        operation: 'list',
        parameters: { owner: 'example', repo: 'input-method', state: 'open', head: 'example:codex/topic', per_page: 100 }
    }]);
});

test('a confirmed mergeable PR for the exact same pushed head replaces push checks', async () => {
    const outcome = await decision({ listed: [pullRequest()] });
    assert.equal(outcome.run, false);
    assert.equal(outcome.calls[1].parameters.pull_number, 42);
    assert.equal(outcome.messages.length, 1);
});

test('PR, tag and manual events always run checks without querying other PRs', async () => {
    for (const context of [
        { ...pushContext, eventName: 'pull_request', ref: 'refs/pull/42/merge' },
        { ...pushContext, ref: 'refs/tags/codex/topic' },
        { ...pushContext, eventName: 'workflow_dispatch' }
    ]) {
        const outcome = await decision({ listed: [pullRequest()] }, context);
        assert.equal(outcome.run, true);
        assert.deepEqual(outcome.calls, []);
    }
});

test('another fork, branch or commit cannot suppress the pushed head', async () => {
    const source = pullRequest().head;
    for (const head of [
        { ...source, repo: { full_name: 'contributor/input-method' } },
        { ...source, ref: 'codex/other' },
        { ...source, sha: 'b'.repeat(40) },
        { ...source, repo: null }
    ]) {
        const outcome = await decision({ listed: [pullRequest({ head })] });
        assert.equal(outcome.run, true);
        assert.equal(outcome.calls.length, 1);
    }
});

test('conflicted or not-yet-computed PRs leave push checks enabled', async () => {
    for (const mergeable of [false, null, undefined]) {
        const outcome = await decision({ listed: [pullRequest({ mergeable })] });
        assert.equal(outcome.run, true);
    }
});

test('a PR closed or changed between listing and reading cannot suppress checks', async () => {
    for (const current of [
        pullRequest({ state: 'closed' }),
        pullRequest({ head: { ...pullRequest().head, sha: 'b'.repeat(40) } })
    ]) {
        const outcome = await decision({ listed: [pullRequest()], current });
        assert.equal(outcome.run, true);
    }
});

test('API list or detail failures run checks and give a bounded warning', async () => {
    for (const options of [
        { listError: new Error('synthetic private response') },
        { listed: [pullRequest()], getError: new Error('synthetic private response') }
    ]) {
        const outcome = await decision(options);
        assert.equal(outcome.run, true);
        assert.equal(outcome.warnings.length, 1);
        assert.equal(outcome.warnings.join().includes('private response'), false);
    }
});

test('repository case is normalized while branch case remains exact', async () => {
    const sameRepository = pullRequest({
        head: { ...pullRequest().head, repo: { full_name: 'Example/Input-Method' } }
    });
    assert.equal((await decision({ listed: [sameRepository] })).run, false);
    const differentBranch = pullRequest({ head: { ...pullRequest().head, ref: 'Codex/topic' } });
    assert.equal((await decision({ listed: [differentBranch] })).run, true);
});

test('one eligible PR is enough while a conflicted sibling never cancels another PR', async () => {
    const outcome = await decision({
        listed: [pullRequest({ number: 41, mergeable: false }), pullRequest()]
    });
    assert.equal(outcome.run, false);
    assert.deepEqual(outcome.calls.filter(call => call.operation === 'get')
        .map(call => call.parameters.pull_number), [41, 42]);
});
