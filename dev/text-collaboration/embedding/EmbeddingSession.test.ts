/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { EmbeddingSession } from './EmbeddingSession.ts'

const state = { format: 1 as const, context: { type: 'file', id: 42 }, baseVersionEtag: 'base',
	version: 3, markdown: 'Text', documentState: 'AA==', stateVector: 'AA==' }

function fixture(edited = true) {
	const order: string[] = []
	const session = new EmbeddingSession({
		checkpoint: () => state,
		freeze: () => { order.push('freeze') },
		drain: async () => { order.push('drain') },
		hasLocalEdits: () => edited,
		save: async () => { order.push('save'); return true },
		close: async () => { order.push('close') },
	})
	return { session, order }
}

test('the host owns checkpoint/save/close ordering', async () => {
	const { session, order } = fixture()
	const persist = async () => { order.push('persist') }
	const first = session.finish(persist)
	assert.equal(session.finish(persist), first)
	assert.equal((await first).closed, true)
	assert.deepEqual(order, ['freeze', 'persist', 'drain', 'persist', 'save', 'close'])
})

test('a failed host checkpoint prevents drain, save and close', async () => {
	const { session, order } = fixture()
	await assert.rejects(session.finish(async () => { throw new Error('Disk full') }), /Disk full/)
	assert.deepEqual(order, ['freeze'])
	assert.deepEqual(session.exportState(), state)
})

test('no local edits require no host file save', async () => {
	const { session, order } = fixture(false)
	assert.equal((await session.finish(async () => {})).saved, false)
	assert.equal(order.includes('save'), false)
})
