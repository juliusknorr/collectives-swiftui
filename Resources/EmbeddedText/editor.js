(() => {
    let instance;
    let session;
    let revision = 0;
    let operations = Promise.resolve();
    const post = (message) => window.webkit?.messageHandlers.textEditor.postMessage(message);
    const enqueue = (operation) => {
        operations = operations.then(operation).catch(error => {
            console.error(error);
            window.reportTextError();
        });
        return operations;
    };
    const create = async (markdown, readOnly) => {
        instance?.destroy();
        let signalLoaded;
        const loaded = new Promise(resolve => { signalLoaded = resolve });
        instance = await window.OCA.Text.createMarkdownContentEditor({
            el: document.getElementById('editor'), content: markdown, readOnly,
            openLinkHandler: () => {},
            onLoaded: signalLoaded,
            onUpdate: ({ markdown }) => {
                if (session) post({ type: 'update', session, revision: ++revision, markdown });
            },
        });
        await loaded;
        document.getElementById('status').hidden = true;
        return instance;
    };
    window.startTextEditor = (input) => enqueue(async () => {
        // Drop the previous document's undo history and selection, retaining the
        // parsed JS modules, loaded styles and WebKit process for fast switches.
        session = undefined;
        revision = 0;
        await create(input.markdown, false);
        session = input.session;
        post({ type: 'loaded', session });
        return instance;
    });
    window.finishTextEditor = () => enqueue(() => {
        instance?.setReadOnly(true);
        instance?.destroy();
        instance = undefined;
        const finished = session;
        session = undefined;
        post({ type: 'finished', session: finished });
    });
    enqueue(async () => { await create('', true); post({ type: 'warmed' }) });
    post({ type: 'ready' });
    if (!window.webkit?.messageHandlers.textEditor) {
        window.startTextEditor({ session: 'browser-smoke', markdown: '# Offline Text\n\nEdit **rich text** without a server.\n\n- [ ] Test a task\n' });
    }
})();
