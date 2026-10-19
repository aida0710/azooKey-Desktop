import os, sys, tempfile
sys.path.insert(0, '/opt/azookey-tree')
from azookey.bridge import Bridge
from azookey.keymap import translate
with tempfile.TemporaryDirectory() as temp:
    os.environ['AZOOKEY_DATA_DIR'] = temp
    bridge = Bridge()
    try:
        for char in 'nihongo':
            bridge.request('key', event=translate(ord(char), 0))
        state = bridge.request('key', event=translate(32, 0))
        assert state['zenzaiLoaded'], 'Zenzai model did not load'
        candidate = next(c for c in state['candidates'] if c['text'] == '日本語')
        result = bridge.request('select', index=candidate['index'], generation=state['generation'], submit=True)
        assert result['commits'] == ['日本語']
        assert result['preedit'] == ''
        print('PASS: installed package, bundled runtime/resources, CPU model, Japanese conversion and commit')
    finally:
        bridge.close()
