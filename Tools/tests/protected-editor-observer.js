/* Observe this fixture's own native DOM input without injecting document edits. */
(() => {
  const editors = [...document.querySelectorAll('input')];
  const output = document.querySelector('#state');
  const compositions = new Map(editors.map(editor => [editor.id, {active: false, text: ''}]));
  const observations = [];
  // Keep long manual sessions bounded while preserving the newest trial.
  const maximumObservations = 2000;
  let nextObservationSequence = 1;
  let droppedObservationCount = 0;

  function observationStatus() {
    return {
      capacity: maximumObservations,
      retainedCount: observations.length,
      droppedCount: droppedObservationCount,
      firstSequence: observations[0]?.sequence ?? null,
      lastSequence: observations.at(-1)?.sequence ?? null,
    };
  }

  function snapshot() {
    return {
      observedAt: Date.now() / 1000,
      monotonicMS: performance.now(),
      timeOrigin: performance.timeOrigin,
      windowActive: document.hasFocus(),
      observationHistory: observationStatus(),
      toolkit: {name: 'Chromium DOM', userAgent: navigator.userAgent},
      fields: editors.map(editor => ({
        id: editor.id,
        label: editor.labels[0].textContent,
        text: editor.value,
        focused: document.hasFocus() && document.activeElement === editor,
        composition: {...compositions.get(editor.id)},
        selection: {startUTF16: editor.selectionStart, endUTF16: editor.selectionEnd,
                    direction: editor.selectionDirection},
        attributes: {
          editable: !editor.readOnly && !editor.disabled,
          type: editor.type,
          inputMode: editor.inputMode,
          autocomplete: editor.autocomplete,
          readOnly: editor.readOnly,
        },
      })),
    };
  }

  function observe(event, fieldId = null) {
    const state = snapshot();
    observations.push({
      sequence: nextObservationSequence++,
      observedAt: state.observedAt, monotonicMS: state.monotonicMS,
      event: event.type, fieldId, text: event.data ?? null,
      inputType: event.inputType ?? null,
      key: event.key ?? null, isComposing: event.isComposing ?? null,
      state,
    });
    if (observations.length > maximumObservations) {
      observations.shift();
      droppedObservationCount += 1;
    }
    state.observationHistory = observationStatus();
    output.textContent = JSON.stringify(state, null, 2);
  }

  for (const editor of editors) {
    for (const type of ['compositionstart', 'compositionupdate', 'compositionend']) {
      editor.addEventListener(type, event => {
        compositions.set(editor.id, {
          active: type !== 'compositionend',
          text: type === 'compositionend' ? '' : event.data,
        });
        observe(event, editor.id);
      });
    }
    for (const type of ['beforeinput', 'input', 'focus', 'blur', 'select', 'keydown', 'keyup']) {
      editor.addEventListener(type, event => observe(event, editor.id));
    }
  }
  document.addEventListener('selectionchange', event => observe(event));
  window.addEventListener('focus', event => observe(event));
  window.addEventListener('blur', event => observe(event));
  window.imeFixture = Object.freeze({
    snapshot,
    observationStatus,
    observations: () => structuredClone(observations),
  });
  observe({type: 'ready'});
})();
