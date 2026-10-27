// Bridge lifecycle and page isolation without installing a browser toolchain.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const messages = [];
let options;
let destroys = 0;
let creates = 0;
let resets = 0;
let readOnly = false;
const window = {
    webkit: { messageHandlers: { textEditor: { postMessage(value) { messages.push(value) } } } },
    OCA: { Text: { async createMarkdownContentEditor(input) {
        creates++; options = input; input.onLoaded();
        return {
            setReadOnly(value) { readOnly = value }, destroy() { destroys++ },
            resetMarkdownContent(content, editable) { resets++; options.content = content; readOnly = !editable; return { canUndo: false, canRedo: false, editable } },
        };
    } } },
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
    assert.equal(messages.filter(message => message.type === 'update').length, 0);
    assert.equal(status.hidden, true);
    assert.equal(options.fileId, undefined, 'Must not enter a server session');
    options.onUpdate({ markdown: '# Changed' });
    options.onUpdate({ markdown: '# Changed again' });
    await window.finishTextEditor();
    assert.deepEqual(messages.map(message => message.type), ['ready', 'warmed', 'loaded', 'update', 'update', 'finished']);
    assert.equal(messages[3].revision, 1);
    assert.equal(messages[4].revision, 2);
    assert.equal(messages[4].session, 'one');
    assert.equal(readOnly, true);
    assert.equal(destroys, 0, 'Page switches must keep the editor mounted');
    assert.equal(options.content, '', 'A closed page must not retain document content');
    await window.startTextEditor({ session: 'two', markdown: 'replacement' });
    assert.equal(options.content, 'replacement');
    options.onUpdate({ markdown: 'second page' });
    assert.equal(messages.at(-1).session, 'two');
    assert.equal(messages.at(-1).revision, 1, 'New page has independent revision/history');
    await window.finishTextEditor();
    // Queue a page switch while initialization is still pending.
    const third = window.startTextEditor({ session: 'three', markdown: 'third' });
    const finished = window.finishTextEditor();
    await Promise.all([third, finished]);
    assert.equal(messages.at(-1).type, 'finished');
    assert.equal(messages.at(-1).session, 'three');
    assert.equal(creates, 1, 'Reuse the warmed editor across all pages');
    assert.equal(resets, 7, 'Reset each opened and closed document');
    console.log('Offline Text mounted-editor/flush/page-isolation contracts passed.');
})().catch(error => { console.error(error); process.exitCode = 1 });
