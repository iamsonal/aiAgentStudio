/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

import { explain } from 'c/agentRunGuide';

describe('agentRunGuide', () => {
    it('explains a known code with what to do', () => {
        expect(explain('BUDGET_EXCEEDED', 'raw')).toMatchObject({ title: 'The run used its whole budget', message: 'raw' });
        expect(explain('BUDGET_EXCEEDED').action).toContain('Max Tool Calls');
    });

    it('explains provider errors by their shape', () => {
        expect(explain('OPENAI_API_429_RATE_LIMIT_EXCEEDED').title).toBe('The model provider was unavailable');
        expect(explain('CLAUDE_API_401_AUTHENTICATION_ERROR').title).toBe('The model provider rejected the request');
    });

    it('falls back to the code in words and the raw message', () => {
        expect(explain('SOMETHING_NEW', 'raw message')).toMatchObject({ title: 'Something new', detail: 'raw message', action: '' });
        expect(explain(null)).toBeNull();
    });
});
