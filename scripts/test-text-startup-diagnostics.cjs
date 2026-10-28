const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const messages = [];
const listeners = new Map();
const window = {
    addEventListener(type, handler) { listeners.set(type, handler) },
    webkit: { messageHandlers: { textEditor: { postMessage(message) { messages.push(message) } } } },
};
const status = { textContent: '' };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../Resources/EmbeddedText/bootstrap.js'), 'utf8'), {
    window, document: { getElementById() { return status } },
});
const privateContent = 'Private document text and credentials must never enter diagnostics';
window.reportTextError({ name: 'TypeError', message: privateContent }, 'warming');
assert.equal(messages.at(-1).phase, 'warming');
assert.equal(messages.at(-1).code, 'TypeError');
assert.equal(messages.at(-1).source, 'unknown');
listeners.get('error')({
    message: 'ResizeObserver loop completed with undelivered notifications.',
    filename: 'file:///private/user/path/EmbeddedText/vendor/text.js', lineno: 12, colno: 34,
});
assert.equal(messages.at(-1).code, 'ResizeObserverLoop');
assert.equal(messages.at(-1).source, 'vendor');
assert.equal(messages.at(-1).line, 12);
assert.equal(messages.at(-1).column, 34);
listeners.get('unhandledrejection')({ reason: { name: privateContent, message: privateContent } });
assert.equal(messages.at(-1).code, 'Unknown');
window.reportTextError({ name: privateContent, message: privateContent }, privateContent);
assert.equal(messages.at(-1).phase, 'runtime');
assert.equal(messages.at(-1).code, 'Unknown');
window.reportTextError({ name: 'TypeError', message: privateContent,
    stack: 'TypeError: ' + privateContent + '\nstart@file:///private/user/path/EmbeddedText/editor.js:42:9' }, 'starting');
assert.equal(messages.at(-1).phase, 'starting');
assert.equal(messages.at(-1).source, 'adapter');
assert.equal(messages.at(-1).line, 42);
assert.equal(messages.at(-1).column, 9);
assert.equal(messages.length, 5, 'Diagnostics must continue reporting genuine failures');
assert.ok(status.textContent.includes('could not load'));
assert.ok(!JSON.stringify(messages).includes(privateContent));
assert.ok(!JSON.stringify(messages).includes('/private/user/path'));
console.log('Text startup diagnostics classification and content isolation passed.');
