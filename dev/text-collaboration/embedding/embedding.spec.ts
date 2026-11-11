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

test('toolbar-only edits are saved without DOM input events', async ({ page, request }) => {
	await page.goto(fixture + '?peer=A')
	await expect(page.getByRole('button', { name: 'Save and close' })).toBeEnabled()
	const editor = page.locator('.ProseMirror[contenteditable=true]')
	await editor.click()
	await editor.press('ControlOrMeta+a')
	await page.evaluate(() => {
		Object.assign(window, { embeddingInputCount: 0 })
		document.querySelector('#editor')!.addEventListener('input', () => {
			(window as any).embeddingInputCount++
		})
	})
	await page.getByRole('button', { name: 'Bold', exact: true }).click()
	await expect(editor.locator('strong').first()).toBeVisible()
	expect(await page.evaluate(() => (window as any).embeddingInputCount)).toBe(0)
	await page.getByRole('button', { name: 'Save and close' }).click()
	await expect(page.getByRole('status')).toContainText('Closed · Save confirmed')
	const canonical = await (await request.get('/host/canonical')).json()
	expect(canonical.markdown).toContain('**Shared starting text.**')
})

test('public export retains unsynced edits after a rejected push', async ({ page }) => {
	await page.goto(fixture + '?peer=A')
	await expect(page.getByRole('button', { name: 'Export Yjs state' })).toBeEnabled()
	await page.getByRole('button', { name: 'Export Yjs state' }).click()
	const before = JSON.parse((await page.locator('#checkpoint').textContent())!)
	await page.getByRole('button', { name: 'Disconnect', exact: true }).click()
	const editor = page.locator('.ProseMirror[contenteditable=true]')
	await editor.click()
	await editor.press('ControlOrMeta+End')
	await editor.pressSequentially(' Recover rejected work')
	await page.route('**/host/A/push', (route) => route.fulfill({ status: 403, json: {} }))
	const rejected = page.waitForResponse((response) => response.url().endsWith('/push') && response.status() === 403)
	await page.getByRole('button', { name: 'Reconnect', exact: true }).click()
	await rejected
	await expect(page.locator('.ProseMirror')).toHaveAttribute('contenteditable', 'false')
	await page.getByRole('button', { name: 'Export Yjs state' }).click()
	const state = JSON.parse((await page.locator('#checkpoint').textContent())!)
	expect(state.baseVersionEtag).toBe(before.baseVersionEtag)
	expect(state.markdown).toContain('Recover rejected work')
	const restored = new Y.Doc()
	Y.applyUpdate(restored, Buffer.from(state.documentState, 'base64'))
	expect(restored.getXmlFragment('default').toString()).toContain('Recover rejected work')
	expect([...Y.encodeStateVector(restored)]).toEqual([...Buffer.from(state.stateVector, 'base64')])
	restored.destroy()
	expect(await page.evaluate(async () => (await fetch('/host/A/close', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).ok)).toBe(true)
})

test('programmatic edits save locally while a remote-only peer skips saving', async ({ browser, request, baseURL }) => {
	const a = await browser.newContext({ baseURL })
	const b = await browser.newContext({ baseURL })
	try {
		const pages = [await a.newPage(), await b.newPage()]
		const before = await (await request.get('/host/info')).json()
		for (const [index, page] of pages.entries()) {
			await page.goto(fixture + '?peer=' + ['A', 'B'][index])
			await expect(page.getByRole('button', { name: 'Save and close' })).toBeEnabled()
		}
		await pages[0].evaluate(() => {
			(window as any).embeddingDemo.instance.insertAtCursor('Programmatic edit ')
		})
		await expect(pages[1].locator('.ProseMirror')).toContainText('Programmatic edit')
		for (const [index, page] of pages.entries()) {
			await page.getByRole('button', { name: 'Save and close' }).click()
			await expect(page.getByRole('status')).toContainText(index === 0 ? 'Save confirmed' : 'No local edits; no file save')
		}
		const after = await (await request.get('/host/info')).json()
		expect(after.counts.B.save ?? 0).toBe(before.counts.B.save ?? 0)
		expect((await (await request.get('/host/canonical')).json()).markdown).toContain('Programmatic edit')
	} finally {
		await a.close()
		await b.close()
	}
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
