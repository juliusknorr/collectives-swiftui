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
window.reportTextError = () => {
    const status = document.getElementById('status');
    if (status) status.textContent = 'The experimental editor could not load. Close it to use Markdown source.';
    window.webkit?.messageHandlers.textEditor.postMessage({ type: 'error' });
};
window.addEventListener('error', window.reportTextError);
window.addEventListener('unhandledrejection', window.reportTextError);
