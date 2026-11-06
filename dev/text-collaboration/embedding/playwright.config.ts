/**
 * SPDX-FileCopyrightText: 2026 Nextcloud contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 */

import { defineConfig, devices } from '@playwright/test'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('./', import.meta.url))


export default defineConfig({
	testDir: '.',
	testMatch: '*.spec.ts',
	workers: 1,
	timeout: 90_000,
	expect: { timeout: 20_000 },
	use: { ...devices['Desktop Chrome'], baseURL: 'http://127.0.0.1:8094', trace: 'retain-on-failure' },
	webServer: {
		command: 'node host.ts', cwd: root, url: 'http://127.0.0.1:8094/host/info',
		reuseExistingServer: false, env: { TEXT_EMBEDDING_PORT: '8094' },
		gracefulShutdown: { signal: 'SIGTERM', timeout: 20_000 },
	},
})
