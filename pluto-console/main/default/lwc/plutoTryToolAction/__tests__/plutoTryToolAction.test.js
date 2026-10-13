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

import { createElement } from 'lwc';
import PlutoTryToolAction from 'c/plutoTryToolAction';
import ToolTryModal from 'c/toolTryModal';

jest.mock('c/toolTryModal', () => ({ __esModule: true, default: { open: jest.fn(() => Promise.resolve()) } }));

describe('c-pluto-try-tool-action', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('opens a dry run of the tool the action ran on', async () => {
        const element = createElement('c-pluto-try-tool-action', { is: PlutoTryToolAction });
        element.recordId = 'a00000000000000AAA';
        document.body.appendChild(element);

        await element.invoke();

        expect(ToolTryModal.open).toHaveBeenCalledWith({ size: 'medium', label: 'Try tool', toolId: 'a00000000000000AAA' });
    });
});
