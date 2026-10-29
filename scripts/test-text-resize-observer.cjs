const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const frames = new Map();
let frameID = 0;
class NativeResizeObserver {
    constructor(callback) { this.callback = callback; this.targets = new Set(); }
    observe(target) { this.targets.add(target); }
    unobserve(target) { this.targets.delete(target); }
    disconnect() { this.targets.clear(); }
    deliver(entries) { this.callback(entries, this); }
}
const window = {
    ResizeObserver: NativeResizeObserver,
    requestAnimationFrame(callback) { frames.set(++frameID, callback); return frameID; },
    cancelAnimationFrame(id) { frames.delete(id); },
    addEventListener() {},
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../Resources/EmbeddedText/bootstrap.js'), 'utf8'), {
    window, document: {},
});
function nextFrame() {
    const pending = [...frames.values()];
    frames.clear();
    for (const callback of pending) callback();
}

const first = {}, second = {};
const calls = [];
const observer = new window.ResizeObserver((entries, instance) => calls.push({ entries, instance }));
observer.observe(first);
observer.observe(second);
observer.deliver([{ target: first, width: 900 }]);
observer.deliver([{ target: first, width: 390 }, { target: second, width: 44 }]);
assert.equal(calls.length, 0, 'Toolbar changes must not run during resize delivery');
assert.equal(frames.size, 1, 'Resize notifications must share one pending frame');
nextFrame();
assert.equal(calls.length, 1);
assert.deepEqual(Array.from(calls[0].entries, entry => entry.width), [390, 44]);
assert.equal(calls[0].instance, observer);

observer.deliver([{ target: first }, { target: second }]);
observer.unobserve(first);
nextFrame();
assert.deepEqual(Array.from(calls.at(-1).entries, entry => entry.target), [second]);
observer.deliver([{ target: second }]);
observer.unobserve(second);
assert.equal(frames.size, 0, 'An unmounted toolbar must not receive a stale callback');

observer.observe(first);
observer.deliver([{ target: first }]);
observer.disconnect();
assert.equal(frames.size, 0);
nextFrame();
assert.equal(calls.length, 2);
observer.observe(first);
observer.deliver([{ target: first }]);
nextFrame();
assert.equal(calls.length, 3, 'An observer can be reused after disconnecting');

let rounds = 0;
const resizing = new window.ResizeObserver(() => {
    if (++rounds === 1) resizing.deliver([{ target: first }]);
});
resizing.deliver([{ target: first }]);
nextFrame();
assert.equal(rounds, 1, 'A callback that resizes again must wait for another frame');
nextFrame();
assert.equal(rounds, 2);

const throwing = new window.ResizeObserver(() => { throw new Error('genuine failure'); });
throwing.deliver([{ target: first }]);
assert.throws(nextFrame, /genuine failure/, 'Real callback exceptions must remain visible');
assert.throws(() => new window.ResizeObserver(null), /callback must be a function/);
console.log('Text resize notifications defer, batch, cancel, and preserve genuine failures.');
