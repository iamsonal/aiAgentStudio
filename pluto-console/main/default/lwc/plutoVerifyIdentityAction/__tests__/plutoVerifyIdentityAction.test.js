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
import PlutoVerifyIdentityAction from 'c/plutoVerifyIdentityAction';
import verifyExecutionIdentity from '@salesforce/apex/AgentRunOperatorController.verifyExecutionIdentity';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';

jest.mock('@salesforce/apex/AgentRunOperatorController.verifyExecutionIdentity', () => ({ default: jest.fn() }), { virtual: true });

function makeAction() {
    const element = createElement('c-pluto-verify-identity-action', { is: PlutoVerifyIdentityAction });
    element.recordId = 'a0B000000000001AAA';
    const toasts = [];
    element.addEventListener('lightning__showtoast', (event) => toasts.push(event.detail));
    document.body.appendChild(element);
    return { element, toasts };
}

describe('c-pluto-verify-identity-action', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('verifies the identity, reports the result, and refreshes the page to show it', async () => {
        verifyExecutionIdentity.mockResolvedValue({ verified: false, message: 'The credential signs in as a different user.' });
        const { element, toasts } = makeAction();

        await element.invoke();

        expect(verifyExecutionIdentity).toHaveBeenCalledWith({ identityId: 'a0B000000000001AAA' });
        expect(toasts[0]).toMatchObject({ title: 'Verify found a problem', message: 'The credential signs in as a different user.', variant: 'warning' });
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([{ recordId: 'a0B000000000001AAA' }]);
    });

    it('shows the refusal to someone not allowed to verify, and changes nothing', async () => {
        verifyExecutionIdentity.mockRejectedValue({ body: { message: 'You need the Agent Operator permission to verify an identity.' } });
        const { element, toasts } = makeAction();

        await element.invoke();

        expect(toasts[0]).toMatchObject({ title: 'Verify failed', message: 'You need the Agent Operator permission to verify an identity.', variant: 'error' });
        expect(notifyRecordUpdateAvailable).not.toHaveBeenCalled();
    });

    it('runs once when clicked again while verifying', async () => {
        let finish;
        verifyExecutionIdentity.mockReturnValue(new Promise((resolve) => (finish = resolve)));
        const { element } = makeAction();

        const first = element.invoke();
        await element.invoke();
        finish({ verified: true, message: 'Signed in as the selected user.' });
        await first;

        expect(verifyExecutionIdentity).toHaveBeenCalledTimes(1);
    });
});
