/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

// Minimal Nextcloud shell. Authentication stays in the loopback host process.
Object.assign(window, {
	OC: { config: { modRewriteWorking: true }, coreApps: [], filePath: (_app: string, _type: string, path: string) => `/js/${path}` },
	OCA: { Text: { OpenReadOnlyEnabled: false } },
	_oc_webroot: '',
	_oc_appswebroots: { text: '' },
	_oc_config: { loglevel: 3 },
	_oc_capabilities: {},
	_oc_isadmin: false,
	_nc_initial_state: new Map<string, unknown>([
		['#initial-state-text-is_full_width_editor', false],
		['#initial-state-text-notify_push', false],
		['#initial-state-text-open_read_only', false],
		['#initial-state-core-capabilities', {}],
	]),
})
