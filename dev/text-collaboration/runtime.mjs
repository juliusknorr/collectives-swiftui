import { c as axios } from './js/index-Ba6lCzlV.chunk.mjs';
import './js/text-editor.mjs';

window._nc_initial_state.set('#initial-state-text-notify_push', false);
window._nc_initial_state.set('#initial-state-text-open_read_only', false);

axios.defaults.adapter = async config => {
    const match = /^(?:\/index\.php)?\/?apps\/text\/session\/(?:file\/\d+\/create|[^/]+\/(sync|push|save|close))$/.exec(config.url);
    if (!match) throw new Error('Request outside the native session bridge');
    const operation = config.url.endsWith('/create') ? 'create' : match[1];
    const result = await window.webkit.messageHandlers.textTransport.postMessage({
        operation, body: typeof config.data === 'string' ? JSON.parse(config.data) : (config.data || {}),
    });
    if (result.status < 200 || result.status >= 300) {
        const error = new Error(`Native transport status ${result.status}`);
        error.response = { status: result.status, data: result.data };
        throw error;
    }
    return { data: result.data, status: result.status, statusText: '', headers: {}, config };
};

let instance;
const component = () => instance.spikeComponent();
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

window.spike = {
    async start(fileID) {
        instance = await window.OCA.Text.createCollaborativeEditor({
            el: document.getElementById('editor'), context: { type: 'file', id: fileID },
            autofocus: false, openLinkHandler: () => {},
        });
        document.getElementById('status').hidden = true;
    },
    state() {
        const c = component();
        return { markdown: c.serialize(), loaded: c.contentLoaded,
            version: c.syncService.version, savedVersion: c.document?.lastSavedVersion ?? -1,
            editable: c.editor.isEditable, error: c.syncError?.type ?? null,
            pending: !!c.ydoc.store.pendingStructs };
    },
    checkpoint() {
        return component().saveService.getSaveData();
    },
    append(text) {
        const c = component();
        c.editor.commands.insertContentAt(c.editor.state.doc.content.size - 1, text);
        return this.state();
    },
    async drain() {
        const c = component();
        c.editor.setEditable(false, false);
        c.saveService.clearAutosave();
        await c.syncService.sendRemainingSteps();
        // Upstream may already have a push in flight. Keep the provider alive
        // while native code verifies convergence and the saved version.
        await sleep(300);
        return this.state();
    },
    async save() {
        const c = component();
        await c.saveService.save({ manualSave: true });
        return this.state();
    },
    async close() {
        const c = component();
        c.saveService.clearAutosave();
        await c.syncService.close();
        c.syncProvider?.destroy();
        return this.state();
    },
    reconnect() {
        component().syncService.syncUp();
    },
};
window.webkit.messageHandlers.textEditor.postMessage({ type: 'ready' });
