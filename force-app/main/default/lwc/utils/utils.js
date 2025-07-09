/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { reduceErrors } from './ldsUtils';
import { logger, LOG_LEVEL } from './logger';


function showToast(title, message, variant) {
    dispatchEvent(
        new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
            mode: 'dismissable'
        })
    );
}

export function showError(error) {
    const errorMessage = reduceErrors(error).join(', ');
    showToast('Error', errorMessage, 'error');
}

export function showSuccess(message) {
    showToast('Success', message, 'success');
}


export { logger, LOG_LEVEL };