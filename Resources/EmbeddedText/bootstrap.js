// Resize callbacks can resize the responsive toolbar again. Run them in the next
// frame to avoid WebKit's resize-loop error, which file origins may redact to
// "Script error." and incorrectly present as a fatal editor failure.
if (typeof window.ResizeObserver === 'function') {
    const NativeResizeObserver = window.ResizeObserver;
    window.ResizeObserver = class extends NativeResizeObserver {
        #pending = new Map();
        #frame = null;
        constructor(callback) {
            if (typeof callback !== 'function') throw new TypeError('ResizeObserver callback must be a function');
            super((entries, observer) => {
                for (const entry of entries) this.#pending.set(entry.target, entry);
                if (this.#frame !== null) return;
                this.#frame = window.requestAnimationFrame(() => {
                    this.#frame = null;
                    const pending = [...this.#pending.values()];
                    this.#pending.clear();
                    if (pending.length) callback(pending, observer);
                });
            });
        }
        disconnect() {
            super.disconnect();
            this.#pending.clear();
            this.#cancelFrame();
        }
        unobserve(target) {
            super.unobserve(target);
            this.#pending.delete(target);
            if (!this.#pending.size) this.#cancelFrame();
        }
        #cancelFrame() {
            if (this.#frame !== null) window.cancelAnimationFrame(this.#frame);
            this.#frame = null;
        }
    };
}

// Local Nextcloud host shim. No account details or credentials enter this runtime.
window.OC = {
    config: { modRewriteWorking: true },
    coreApps: [],
    filePath(_app, _type, path) { return new URL('vendor/' + path, document.baseURI).href },
};
window.OCA = {};
window._oc_webroot = '';
window._oc_appswebroots = { text: 'vendor' };
window._oc_config = { loglevel: 3 };
window._nc_initial_state = new Map([
    ['#initial-state-text-is_full_width_editor', false],
    ['#initial-state-core-capabilities', {}],
]);
window._oc_capabilities = {};
window._oc_isadmin = false;
window.reportTextError = (failure, phase = 'runtime') => {
    const error = failure?.error ?? failure?.reason ?? failure;
    const message = failure?.message ?? error?.message;
    // WebKit defers undelivered resize notifications to the next frame. The
    // editor remains usable, so this layout notification must not end a session.
    if (message === 'ResizeObserver loop completed with undelivered notifications.'
        || message === 'ResizeObserver loop limit exceeded') return;
    const names = ['TypeError', 'ReferenceError', 'SyntaxError', 'RangeError', 'URIError',
        'EvalError', 'AbortError', 'NotFoundError', 'InvalidStateError', 'SecurityError'];
    const code = names.includes(error?.name) ? error.name : 'Unknown';
    const location = typeof error?.stack === 'string'
        ? /(?:vendor\/text\.js|editor\.js|bootstrap\.js):(\d+):(\d+)/.exec(error.stack) : null;
    const filename = failure?.filename ?? error?.fileName
        ?? (location ? '/' + location[0].replace(/:\d+:\d+$/, '') : undefined);
    const line = failure?.lineno ?? error?.lineNumber ?? (location ? Number(location[1]) : 0);
    const column = failure?.colno ?? error?.columnNumber ?? (location ? Number(location[2]) : 0);
    const source = typeof filename !== 'string' ? 'unknown'
        : filename.endsWith('/vendor/text.js') ? 'vendor'
        : filename.endsWith('/editor.js') ? 'adapter'
        : filename.endsWith('/bootstrap.js') ? 'host' : 'unknown';
    const status = document.getElementById('status');
    if (status) status.textContent = 'The experimental editor could not load. Close it to use Markdown source.';
    window.webkit?.messageHandlers.textEditor.postMessage({
        type: 'error', code, source,
        phase: ['warming', 'starting', 'finishing'].includes(phase) ? phase : 'runtime',
        line: Number.isSafeInteger(line) ? line : 0,
        column: Number.isSafeInteger(column) ? column : 0,
    });
};
window.addEventListener('error', window.reportTextError);
window.addEventListener('unhandledrejection', window.reportTextError);
