/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import type { EmbeddingState } from '@text/types/EmbeddingState.ts'
import type { SessionTransport } from '@text/services/SessionTransport.ts'

import './bootstrap.ts'
import { EmbeddingSession } from './EmbeddingSession.ts'

const { createCollaborativeEditor } = await import('@text/createEditor.ts')
const peer = new URLSearchParams(location.search).get('peer') === 'B' ? 'B' : 'A'
const status = document.querySelector<HTMLElement>('#status')!
const connection = document.querySelector<HTMLButtonElement>('#connection')!
const exportButton = document.querySelector<HTMLButtonElement>('#export')!
const finishButton = document.querySelector<HTMLButtonElement>('#finish')!
let online = true
let loaded = false
let closed = false
let edited = false
let checkpoint: EmbeddingState | undefined

/**
 *
 * @param operation Allowlisted session operation.
 * @param body Operation data without credentials.
 */
async function host(operation: string, body: object = {}) {
	if (!online) {
		throw Object.assign(new Error('Disconnected by demo host'), {
			response: {
				status: 503,
			},
		})
	}
	const response = await fetch(`/host/${peer}/${operation}`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify(body),
	})
	const data = await response.json()
	if (!response.ok) {
		throw Object.assign(new Error(`Host request failed (${response.status
		})`), { response: { status: response.status, data } })
	}
	return data
}

const transport: SessionTransport = {
	async openContext(params) {
		const data = await host('create', { type: params.type, id: params.id, baseVersionEtag: params.baseVersionEtag })
		return { data, connection: { documentId: data.document.id, sessionId: data.session.id, sessionToken: data.session.token, baseVersionEtag: data.document.baseVersionEtag, filePath: '' } }
	},
	async sync(_connection, data) { return { data: await host('sync', data) } },
	async push(_connection, data) { return { data: await host('push', data) } },
	async save() { throw new Error('The host controls file saves') },
	async close() { if (!closed) { throw new Error('The host controls session closure') } },
}

const info = await (await fetch('/host/info')).json()
const instance = await createCollaborativeEditor({
	el: document.querySelector<HTMLElement>('#editor')!,
	context: { type: 'file', id: info.fileID },
	sessionTransport: transport,
	autofocus: false,
	openLinkHandler: () => {},
	onLoaded() {
		if (loaded) {
			return
		}
		try {
			instance.exportState()
		} catch {
			status.textContent = `Client ${peer} · Waiting for a usable session`
			return
		}
		loaded = true
		status.textContent = `Client ${peer} · Connected`
		connection.disabled = exportButton.disabled = finishButton.disabled = false
	},
})

/**
 *
 */
function showState() {
	checkpoint = instance.exportState()
	document.querySelector<HTMLDetailsElement>('details')!.open = true
	document.querySelector('#checkpoint')!.textContent = JSON.stringify(checkpoint, null, 2)
	return checkpoint
}

connection.onclick = () => {
	online = !online
	connection.textContent = online ? 'Disconnect' : 'Reconnect'
	status.textContent = `Client ${peer} · ${online ? 'Connected' : 'Offline; edits remain in this Y.Doc'}`
	if (online) {
		// Polling resumes through the same Y.Doc and transport.
	}
}
exportButton.onclick = () => {
	showState()
}
document.querySelector('#editor')!.addEventListener('input', () => { edited = true })
const lifecycle = new EmbeddingSession({
	checkpoint: () => instance.exportState(),
	freeze: () => { document.querySelector<HTMLElement>('#editor')!.inert = true },
	drain: () => instance.drain(),
	hasLocalEdits: () => edited,
	save: async () => {
		const state = instance.exportState()
		const result = await host('save', { version: state.version, autosaveContent: state.markdown,
			documentState: state.documentState, force: false, manualSave: true })
		return result.document.lastSavedVersion >= state.version
	},
	close: async () => { await host('close'); closed = true },
})

finishButton.onclick = async () => {
	finishButton.disabled = true
	try {
		// The loopback host acknowledges atomic checkpoint writes before save/close.
		showState()
		const result = await lifecycle.finish(async (state) => {
			await host('checkpoint', state)
		})
		checkpoint = result.checkpoint
		instance.destroy()
		document.querySelector('#checkpoint')!.textContent = JSON.stringify(result, null, 2)
		status.textContent = `Client ${peer} · Closed · ${result.saved ? 'Save confirmed' : 'No local edits; no file save'}`
		connection.disabled = exportButton.disabled = true
	} catch {
		status.textContent = `Client ${peer} · Finish failed; retain the exported checkpoint for recovery`
	}
}

Object.assign(window, {
	embeddingDemo: {
		instance,
		get checkpoint() {
			return checkpoint
		},
		showState,
	},
})
