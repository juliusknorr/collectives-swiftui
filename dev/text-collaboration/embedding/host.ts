/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import type { IncomingMessage, ServerResponse } from 'node:http'

import vue from '@vitejs/plugin-vue'
import { randomUUID } from 'node:crypto'
import { mkdtemp, open, rename, rm } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createServer as createViteServer } from 'vite'

const appRoot = fileURLToPath(new URL('../../../', import.meta.url))
const textSource = process.env.TEXT_EMBEDDING_SOURCE
if (!textSource) {
	throw new Error('Set TEXT_EMBEDDING_SOURCE to the Text worktree with the public seam and installed dependencies')
}

// Disposable loopback fixture only. Never use production accounts with this host.
const serverURL = new URL(process.env.TEXT_EMBEDDING_SERVER ?? 'http://localhost:18081')
if (serverURL.protocol !== 'http:' || !['localhost', '127.0.0.1'].includes(serverURL.hostname)) {
	throw new Error('The embedding demo requires a disposable loopback HTTP Nextcloud server')
}
const user = process.env.TEXT_EMBEDDING_USER ?? 'spike'
const password = process.env.TEXT_EMBEDDING_PASSWORD ?? 'local-spike-only'
const auth = 'Basic ' + Buffer.from(`${user}:${password}`).toString('base64')
const port = Number(process.env.TEXT_EMBEDDING_PORT ?? 8093)
if (!Number.isSafeInteger(port) || port < 1024 || port > 65535) {
	throw new Error('Invalid embedding host port')
}
const origin = `http://127.0.0.1:${port}`
const initial = '# Embedded Text\n\nShared starting text.\n'
const davPath = `remote.php/dav/files/${encodeURIComponent(user)}/Embedding-${randomUUID()}.md`
const counts: Record<string, Record<string, number>> = { A: {}, B: {} }
type BoundSession = { documentId: string, sessionId: number, sessionToken: string, baseVersionEtag: string }
const sessions: Record<string, BoundSession | undefined> = {}
const limit = 4 * 1024 * 1024
const checkpointDirectory = await mkdtemp(join(tmpdir(), 'text-embedding-'))
const checkpoints: Record<string, number> = { A: 0, B: 0 }

/**
 *
 * @param method HTTP method for the bound test server.
 * @param path Path constructed by the host.
 * @param body Operation data without credentials.
 * @param headers Additional native HTTP headers.
 */
async function request(method: string, path: string, body?: string, headers: Record<string, string> = {}) {
	const response = await fetch(new URL(path, serverURL), {
		method,
		body,
		headers: { Authorization: auth, 'OCS-APIRequest': 'true', 'X-Requested-With': 'XMLHttpRequest', 'Content-Type': 'application/json', ...headers },
		redirect: 'error',
		signal: AbortSignal.timeout(15_000),
	})
	if (Number(response.headers.get('Content-Length') ?? 0) > limit) {
		await response.body?.cancel()
		throw new Error('Response too large')
	}
	const chunks: Uint8Array[] = []
	let size = 0
	for await (const chunk of response.body ?? []) {
		size += chunk.length
		if (size > limit) {
			throw new Error('Response too large')
		}
		chunks.push(chunk)
	}
	return { status: response.status, text: Buffer.concat(chunks).toString(), etag: response.headers.get('ETag') }
}

const created = await request('PUT', davPath, initial, { 'Content-Type': 'text/markdown', 'If-None-Match': '*' })
if (created.status !== 201) {
	throw new Error(`Could not create embedding fixture (${created.status
	})`)
}
const properties = await request(
	'PROPFIND',
	davPath,
	'<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/></d:prop></d:propfind>',
	{ Depth: '0', 'Content-Type': 'application/xml' },
)
const fileID = Number(properties.text.match(/<(?:[\w]+:)?fileid>(\d+)</)?.[1])
if (properties.status !== 207 || !fileID) {
	throw new Error('Could not determine fixture file ID')
}

/**
 *
 * @param value Server response to sanitize recursively.
 */
function sanitized(value: unknown): unknown {
	if (Array.isArray(value)) {
		return value.map(sanitized)
	}
	if (value && typeof value === 'object') {
		return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, ['token', 'sessiontoken'].includes(key.toLowerCase()) ? 'host-owned' : sanitized(child)]))
	}
	return value
}

/**
 *
 * @param req Incoming loopback request.
 */
async function bodyOf(req: IncomingMessage): Promise<Record<string, unknown>> {
	const chunks: Buffer[] = []
	let size = 0
	for await (const chunk of req) {
		size += chunk.length
		if (size > limit) {
			throw new Error('Request too large')
		}
		chunks.push(chunk)
	}
	const value = JSON.parse(Buffer.concat(chunks).toString())
	if (!value || typeof value !== 'object' || Array.isArray(value)) {
		throw new Error('Invalid request body')
	}
	return value
}

const allowed: Record<string, string[]> = {
	create: ['type', 'id', 'baseVersionEtag'],
	sync: ['version'],
	push: ['version', 'steps', 'awareness', 'recoveryAttempt'],
	save: ['version', 'autosaveContent', 'documentState', 'force', 'manualSave'],
	close: [],
}
/**
 *
 * @param peer Assigned demo client.
 * @param operation Allowlisted session operation.
 * @param input Validated browser operation data.
 */
async function bridge(peer: string, operation: string, input: Record<string, unknown>) {
	if (!allowed[operation] || Object.keys(input).some((key) => !allowed[operation].includes(key))) {
		return { status: 400, data: {} }
	}
	counts[peer][operation] = (counts[peer][operation] ?? 0) + 1
	let path: string
	let body: Record<string, unknown>
	if (operation === 'create') {
		if (sessions[peer] || input.type !== 'file' || input.id !== fileID || input.baseVersionEtag) {
			return {
				status: 409,
				data: {

				},
			}
		}
		path = `session/file/${fileID}/create`
		body = {}
	} else {
		const session = sessions[peer]
		if (!session) {
			return {
				status: 403,
				data: {

				},
			}
		}
		if (operation === 'save' && input.force !== false) {
			return {
				status: 400,
				data: {

				},
			}
		}
		path = `session/${encodeURIComponent(session.documentId)}/${operation}`
		body = { ...input, ...session }
	}
	const result = await request(operation === 'create' ? 'PUT' : 'POST', `index.php/apps/text/${path}`, JSON.stringify(body))
	const data = JSON.parse(result.text || '{}')
	if (result.status === 200 && operation === 'create') {
		sessions[peer] = { documentId: data.document.id, sessionId: data.session.id, sessionToken: data.session.token, baseVersionEtag: data.document.baseVersionEtag }
	}
	if (result.status === 200 && operation === 'close') {
		sessions[peer] = undefined
	}
	return { status: result.status, data: sanitized(data) }
}

/**
 *
 * @param peer Assigned demo client.
 * @param data Credential-free Yjs checkpoint.
 */
async function persistCheckpoint(peer: string, data: Record<string, unknown>) {
	const fields = ['format', 'context', 'baseVersionEtag', 'version', 'markdown', 'documentState', 'stateVector']
	const context = data.context as { type?: string, id?: number } | undefined
	if (Object.keys(data).some((key) => !fields.includes(key)) || data.format !== 1
		|| context?.type !== 'file' || context.id !== fileID || data.baseVersionEtag !== sessions[peer]?.baseVersionEtag
		|| !Number.isSafeInteger(data.version) || typeof data.markdown !== 'string') {
		throw new Error('Invalid checkpoint identity')
	}
	for (const key of ['documentState', 'stateVector']) {
		const value = data[key]
		if (typeof value !== 'string' || Buffer.from(value, 'base64').toString('base64') !== value) {
			throw new Error('Invalid checkpoint encoding')
		}
	}
	const path = join(checkpointDirectory, peer + '.json')
	const temporary = path + '.' + randomUUID()
	const file = await open(temporary, 'wx', 0o600)
	try {
		await file.writeFile(JSON.stringify({ server: serverURL.origin, user, fileID, checkpoint: data }))
		await file.sync()
	} finally { await file.close() }
	await rename(temporary, path)
	const directory = await open(checkpointDirectory, 'r')
	try {
		await directory.sync()
	} finally {
		await directory.close()
	}
	checkpoints[peer]++
}

const vite = await createViteServer({
	configFile: false,
	root: appRoot,
	cacheDir: resolve(appRoot, 'dev/text-collaboration/embedding/node_modules/.vite'),
	plugins: [vue()],
	server: { middlewareMode: true, hmr: false, ws: false, fs: { allow: [appRoot, resolve(textSource)] } },
	resolve: { alias: { '@text': resolve(textSource, 'src'), vue: resolve(textSource, 'node_modules/vue/dist/vue.runtime.esm-bundler.js') } },
	css: { modules: { localsConvention: 'camelCase' } },
	define: { 'process.env.NODE_ENV': JSON.stringify('development') },
})
/**
 *
 * @param res Loopback HTTP response.
 * @param status HTTP response status.
 * @param data Sanitized response body.
 */
function json(res: ServerResponse, status: number, data: unknown) {
	res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
	res.end(JSON.stringify(data))
}
const server = createServer(async (req, res) => {
	try {
		if (req.url === '/host/info') {
			json(res, 200, {
				fileID,
				initial,
				counts,
				checkpoints,
			})
			return
		}
		if (req.url === '/host/canonical') {
			const canonical = await request('GET', davPath)
			json(res, canonical.status, {
				markdown: canonical.text,
				etag: canonical.etag,
			})
			return
		}
		const match = req.url?.match(/^\/host\/(A|B)\/(create|sync|push|save|close|checkpoint)$/)
		if (match) {
			if (req.method !== 'POST' || req.headers.origin !== origin || !req.headers['content-type']?.startsWith('application/json')) {
				json(res, 403, {

				})
				return
			}
			const input = await bodyOf(req)
			if (match[2] === 'checkpoint') {
				await persistCheckpoint(match[1], input)
				json(res, 200, {})
				return
			}
			const result = await bridge(match[1], match[2], input)
			json(res, result.status, result.data)
			return
		}
		if (req.url?.startsWith('/host/')) {
			json(res, 404, {

			})
			return
		}
		if (req.url === '/') {
			res.writeHead(302, {
				Location: '/dev/text-collaboration/embedding/index.html',
			})
			res.end()
			return
		}
		vite.middlewares(req, res)
	} catch {
		json(res, 503, { error: 'Embedding host request failed' })
	}
})
server.listen(port, '127.0.0.1', () => {
	process.stdout.write(`Embedding demo: ${origin}/dev/text-collaboration/embedding/index.html\n`)
})

/**
 *
 */
async function stop() {
	await Promise.all(Object.entries(sessions).map(async ([peer, session]) => {
		if (session) {
			await bridge(peer, 'close', {

			}).catch(() => {

			})
		}
	}))
	const deleted = await request('DELETE', davPath)
	if (![204, 404].includes(deleted.status)) {
		process.stderr.write('Embedding fixture cleanup failed\n')
	}
	await rm(checkpointDirectory, { recursive: true, force: true })
	server.close()
	await vite.close()
	process.exit(0)
}
process.once('SIGTERM', stop)
process.once('SIGINT', stop)
