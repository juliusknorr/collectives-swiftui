/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import type { EmbeddingState } from '@text/types/EmbeddingState.ts'

interface SessionOperations {
	checkpoint: () => EmbeddingState
	freeze: () => void
	drain: () => Promise<unknown>
	hasLocalEdits: () => boolean
	save: () => Promise<boolean | undefined>
	close: () => Promise<unknown>
}

export type CheckpointWriter = (state: EmbeddingState) => Promise<void>

export interface EmbeddingFinish {
	checkpoint: EmbeddingState
	saved: boolean
	closed: true
}

/** Failed finishes remain frozen and exportable for host-owned recovery. */
export class EmbeddingSession {
	#operations: SessionOperations
	#finish?: Promise<EmbeddingFinish>
	constructor(operations: SessionOperations) {
		this.#operations = operations
	}

	exportState() {
		return this.#operations.checkpoint()
	}

	finish(persist: CheckpointWriter): Promise<EmbeddingFinish> {
		this.#finish ??= this.#finishOnce(persist)
		return this.#finish
	}

	async #finishOnce(persist: CheckpointWriter): Promise<EmbeddingFinish> {
		const ops = this.#operations
		ops.freeze()
		await persist(ops.checkpoint())
		await ops.drain()
		const checkpoint = ops.checkpoint()
		await persist(checkpoint)
		const saved = ops.hasLocalEdits()
		if (saved && await ops.save() !== true) {
			throw new Error('Text did not confirm the required saved version; retain the checkpoint')
		}
		await ops.close()
		return { checkpoint, saved, closed: true }
	}
}
