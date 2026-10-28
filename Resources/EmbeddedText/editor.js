(() => {
    let instance;
    let session;
    let revision = 0;
    let operations = Promise.resolve();
    const post = (message) => window.webkit?.messageHandlers.textEditor.postMessage(message);
    const enqueue = (operation, phase) => {
        operations = operations.then(operation).catch(error => {
            console.error(error);
            window.reportTextError(error, phase);
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
        // Replace the document in the mounted editor. A fresh EditorState drops
        // undo, selection and plugin state without remounting Vue or Tiptap.
        session = undefined;
        revision = 0;
        instance.resetMarkdownContent(input.markdown, true);
        // Settle plugin/view updates before binding the native draft callback.
        await Promise.resolve();
        session = input.session;
        document.getElementById('editor').inert = false;
        post({ type: 'loaded', session });
        return instance;
    }, 'starting');
    window.finishTextEditor = ({ retainContent = false } = {}) => enqueue(() => {
        const finished = session;
        session = undefined;
        document.getElementById('editor').inert = true;
        if (retainContent) instance?.freezeMarkdownContent();
        else instance?.resetMarkdownContent('', false);
        post({ type: 'finished', session: finished, retained: retainContent });
    }, 'finishing');
    enqueue(async () => {
        // This host only renders the editing UI; disable input directly while idle.
        await create('', false);
        instance.resetMarkdownContent('', false);
        post({ type: 'warmed' });
    }, 'warming');
    post({ type: 'ready' });
    if (!window.webkit?.messageHandlers.textEditor) {
        window.startTextEditor({ session: 'browser-smoke', markdown: '# Offline Text\n\nEdit **rich text** without a server.\n\n- [ ] Test a task\n' });
    }
})();
