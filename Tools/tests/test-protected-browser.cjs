// Requires an existing Playwright installation; this checks DOM widgets, not IME delivery.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require('playwright');

async function main() {
  const browser = await chromium.launch({
    headless: true,
    ...(process.env.AZOOKEY_CHROMIUM ? {executablePath: process.env.AZOOKEY_CHROMIUM} : {}),
  });
  let page;
  const report = {
    scope: 'DOM widgets only; no operating-system IME or privacy-transport claim',
    result: 'running',
    observations: [],
    pageErrors: [],
  };
  try {
    const context = await browser.newContext({offline: true});
    page = await context.newPage();
    page.on('pageerror', error => report.pageErrors.push(String(error)));
    await page.goto(pathToFileURL(path.join(__dirname, 'protected-editor.html')).href);
    await page.locator('#normal').focus();
    for (const fieldId of ['normal', 'password', 'pin']) {
      await page.keyboard.type('TEST123');
      const state = await page.evaluate(() => window.imeFixture.snapshot());
      const field = state.fields.find(field => field.id === fieldId);
      assert.equal(field.focused, true);
      assert.equal(field.text, 'TEST123');
      assert.equal(field.attributes.editable, true);
      assert.equal(field.attributes.type, fieldId === 'normal' ? 'text' : 'password');
      assert.equal(field.attributes.inputMode, fieldId === 'pin' ? 'numeric' : '');
      await page.keyboard.press('Control+A');
      const selected = await page.evaluate(() => window.imeFixture.snapshot());
      assert.deepEqual(
        selected.fields.find(field => field.id === fieldId).selection,
        {startUTF16: 0, endUTF16: 7, direction: 'forward'},
      );
      report.observations.push(state);
      await page.keyboard.press('Tab');
    }
    await page.keyboard.type('MUST_NOT_REPLACE');
    let state = await page.evaluate(() => window.imeFixture.snapshot());
    const readOnly = state.fields.find(field => field.id === 'read-only');
    report.readOnlyFocusedState = state;
    assert.equal(readOnly.focused, true);
    assert.equal(readOnly.attributes.editable, false);
    assert.equal(readOnly.text, 'READ_ONLY_BEFORE TARGET_TEXT READ_ONLY_AFTER');
    await page.keyboard.press('Shift+Tab');
    state = await page.evaluate(() => window.imeFixture.snapshot());
    assert.equal(state.fields.find(field => field.id === 'pin').focused, true);
    assert.equal(state.fields.length, 4);
    const events = await page.evaluate(() => window.imeFixture.observations());
    report.nativeEvents = events;
    const completeHistory = await page.evaluate(() => window.imeFixture.observationStatus());
    assert.equal(completeHistory.droppedCount, 0);
    assert.equal(completeHistory.firstSequence, 1);
    assert.ok(events.some(event => event.event === 'input' && event.fieldId === 'normal'));
    assert.equal(events.some(event => event.event === 'input' && event.fieldId === 'read-only'), false);
    assert.deepEqual(report.pageErrors, []);
    // Deliberately overflow only the observer, without synthesizing document edits.
    // Consumers must be able to reject incomplete event histories.
    await page.evaluate(() => {
      const input = document.querySelector('#normal');
      for (let index = 0; index < 2001; index++) {
        input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Unidentified'}));
      }
    });
    const overflowHistory = await page.evaluate(() => window.imeFixture.observationStatus());
    const retainedEvents = await page.evaluate(() => window.imeFixture.observations());
    assert.equal(overflowHistory.retainedCount, overflowHistory.capacity);
    assert.equal(overflowHistory.droppedCount, events.length + 2001 - overflowHistory.capacity);
    assert.equal(overflowHistory.firstSequence, overflowHistory.droppedCount + 1);
    assert.equal(overflowHistory.lastSequence, events.length + 2001);
    assert.equal(retainedEvents[0].sequence, overflowHistory.firstSequence);
    const afterOverflow = await page.evaluate(() => window.imeFixture.snapshot());
    assert.deepEqual(afterOverflow.fields, state.fields);
    Object.assign(report, {
      result: 'pass',
      final: state,
      nativeEventCount: events.length,
      completeHistory,
      overflowHistory,
    });
    console.log('PASS: keyboard focus, real input attributes, selection and read-only preservation');
  } catch (error) {
    report.result = 'failure';
    report.error = String(error);
    if (page) {
      report.failureObservation = await page.evaluate(() => ({
        state: window.imeFixture?.snapshot(),
        events: window.imeFixture?.observations(),
      })).catch(observationError => ({error: String(observationError)}));
    }
    throw error;
  } finally {
    try {
      if (process.argv[2]) fs.writeFileSync(process.argv[2], JSON.stringify(report, null, 2) + '\n');
    } finally {
      await browser.close();
    }
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
