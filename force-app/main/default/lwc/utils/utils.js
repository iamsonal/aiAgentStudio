/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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
