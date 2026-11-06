/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import { expect, test } from '@playwright/test'
import * as Y from 'yjs'

const fixture = '/dev/text-collaboration/embedding/index.html'

test('no-edit embedding closes without a file save or source rewrite', async ({ page, request }) => {
	const before = await (await request.get('/host/info')).json()
	await page.goto(fixture + '?peer=A')
	await expect(page.getByRole('button', { name: 'Save and close' })).toBeEnabled()
	await page.getByRole('button', { name: 'Save and close' }).click()
	await expect(page.getByRole('status')).toContainText('No local edits; no file save')
	const after = await (await request.get('/host/info')).json()
	expect(after.counts.A.save ?? 0).toBe(before.counts.A.save ?? 0)
	expect((await (await request.get('/host/canonical')).json()).markdown).toBe(before.initial)
})

test('isolated embedded clients converge, export Yjs state, reconnect and confirm save/close', async ({ browser, request, baseURL }) => {
	const a = await browser.newContext({ baseURL })
	const b = await browser.newContext({ baseURL })
	try {
		const pages = [await a.newPage(), await b.newPage()]
		const directRequests: string[] = []
		for (const page of pages) {
			page.on('request', (req) => {
				if (req.url().includes('/apps/text/session/')) {
					directRequests.push(req.url())
				}
			})
			await page.route('**/apps/text/session/**', (route) => route.abort())
		}
		const opened = pages.map((page) => page.waitForResponse((response) => response.url().endsWith('/create')))
		await Promise.all(pages.map((page, index) => page.goto(fixture + '?peer=' + ['A', 'B'][index])))
		for (const response of await Promise.all(opened)) {
			expect((await response.json()).session.token).toBe('host-owned')
		}
		for (const page of pages) {
			await expect(page.getByRole('button', {
				name: 'Export Yjs state',
			})).toBeEnabled()
		}
		const editors = pages.map((page) => page.locator('.ProseMirror[contenteditable=true]'))
		await Promise.all(editors.map(async (editor, index) => {
			await editor.click()
			await editor.press('ControlOrMeta+End')
			await editor.pressSequentially([' Native-α', ' Peer-日本語'][index])
		}))
		for (const editor of editors) {
			await expect(editor).toContainText('Native-α')
			await expect(editor).toContainText('Peer-日本語')
		}
		await pages[1].getByRole('button', { name: 'Disconnect', exact: true }).click()
		await editors[1].pressSequentially(' Offline work')
		await editors[0].pressSequentially(' Online work')
		await pages[1].getByRole('button', { name: 'Reconnect', exact: true }).click()
		for (const editor of editors) {
			await expect(editor).toContainText('Offline work')
			await expect(editor).toContainText('Online work')
		}
		for (const page of pages) {
			await page.getByRole('button', { name: 'Export Yjs state' }).click()
			const state = JSON.parse((await page.locator('#checkpoint').textContent())!)
			expect(state.format).toBe(1)
			expect(Buffer.from(state.documentState, 'base64').length).toBeGreaterThan(0)
			expect(Buffer.from(state.stateVector, 'base64').length).toBeGreaterThan(0)
			expect(state.baseVersionEtag).toBeTruthy()
			expect(Object.keys(state)).not.toContain('sessionToken')
			const restored = new Y.Doc()
			Y.applyUpdate(restored, Buffer.from(state.documentState, 'base64'))
			expect([...Y.encodeStateVector(restored)]).toEqual([...Buffer.from(state.stateVector, 'base64')])
			expect(restored.getXmlFragment('default').toString()).toContain('Offline work')
			restored.destroy()
		}
		for (const page of pages) {
			await page.getByRole('button', { name: 'Save and close' }).click()
			await expect(page.getByRole('status')).toContainText('Closed · Save confirmed')
			await expect(page.locator('.ProseMirror[contenteditable=true]')).toHaveCount(0)
		}
		const canonical = await (await request.get('/host/canonical')).json()
		expect(canonical.etag).toBeTruthy()
		expect(canonical.markdown).toContain('Offline work')
		expect(canonical.markdown).toContain('Online work')
		const info = await (await request.get('/host/info')).json()
		expect(info.checkpoints.A).toBeGreaterThanOrEqual(2)
		expect(info.checkpoints.B).toBeGreaterThanOrEqual(2)
		expect(directRequests).toEqual([])
	} finally {
		await a.close()
		await b.close()
	}
})
