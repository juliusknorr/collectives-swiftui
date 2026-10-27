(() => {
    let instance;
    let session;
    let revision = 0;
    const post = (message) => window.webkit?.messageHandlers.textEditor.postMessage(message);
    window.startTextEditor = async (input) => {
        if (instance || session) return;
        session = input.session;
        try {
            let signalLoaded;
            const loaded = new Promise(resolve => { signalLoaded = resolve });
            instance = await window.OCA.Text.createMarkdownContentEditor({
                el: document.getElementById('editor'),
                content: input.markdown,
                readOnly: false,
                openLinkHandler: () => {},
                onLoaded: () => {
                    document.getElementById('status').hidden = true;
                    post({ type: 'loaded', session });
                    signalLoaded();
                },
                onUpdate: ({ markdown }) => {
                    post({ type: 'update', session, revision: ++revision, markdown });
                },
            });
            await loaded;
            return instance;
        } catch (error) {
            console.error(error);
            window.reportTextError();
        }
    };
    window.finishTextEditor = () => {
        instance?.setReadOnly(true);
        post({ type: 'finished', session });
    };
    // Native calls this after the navigation completes. Standalone browser smoke fixture.
    post({ type: 'ready' });
    if (!window.webkit?.messageHandlers.textEditor) {
        window.startTextEditor({ session: 'browser-smoke', markdown: '# Offline Text\n\nEdit **rich text** without a server.\n\n- [ ] Test a task\n' });
    }
})();
