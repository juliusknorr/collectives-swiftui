// Bridge contract tests without loading Text or installing a browser toolchain.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const messages = [];
let options;
let readOnly = false;
const instance = { setReadOnly(value) { readOnly = value } };
const window = {
    webkit: { messageHandlers: { textEditor: { postMessage(value) { messages.push(value) } } } },
    OCA: { Text: { async createMarkdownContentEditor(input) { options = input; input.onLoaded(); return instance } } },
    reportTextError() { throw new Error('Unexpected adapter error') },
};
const status = { hidden: false };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../Resources/EmbeddedText/editor.js'), 'utf8'), {
    window, document: { getElementById(id) { return id === 'status' ? status : {} } }, console,
});
(async () => {
    assert.equal(messages[0].type, 'ready');
    const markdown = '# 📝 Exact source\n\n<!-- keep -->\n\n日本語';
    await window.startTextEditor({ session: 'one', markdown });
    assert.equal(options.content, markdown);
    assert.equal(messages.filter(message => message.type === 'update').length, 0, 'Opening must not reserialize Markdown');
    assert.equal(status.hidden, true);
    assert.equal(options.fileId, undefined, 'Must not enter a server session');
    options.onUpdate({ markdown: '# Changed' });
    options.onUpdate({ markdown: '# Changed again' });
    window.finishTextEditor();
    assert.deepEqual(messages.map(message => message.type), ['ready', 'loaded', 'update', 'update', 'finished']);
    assert.equal(messages[2].revision, 1);
    assert.equal(messages[3].revision, 2);
    assert.equal(messages[3].session, 'one');
    assert.equal(readOnly, true);
    await window.startTextEditor({ session: 'two', markdown: 'replacement' });
    assert.equal(options.content, markdown, 'A second initialization must not overwrite edits');
    console.log('Offline Text bridge contracts passed.');
})().catch(error => { console.error(error); process.exitCode = 1 });
