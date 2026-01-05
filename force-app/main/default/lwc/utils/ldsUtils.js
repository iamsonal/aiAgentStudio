/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

export function reduceErrors(inputErrors) {
    const errors = Array.isArray(inputErrors) ? inputErrors : [inputErrors];

    return errors

        .filter((error) => !!error)

        .map((error) => {
            if (Array.isArray(error.body)) {
                return error.body.map((e) => e.message);
            } else if (error?.body?.pageErrors && error.body.pageErrors.length > 0) {
                return error.body.pageErrors.map((e) => e.message);
            } else if (error?.body?.fieldErrors && Object.keys(error.body.fieldErrors).length > 0) {
                const fieldErrors = [];
                Object.values(error.body.fieldErrors).forEach((errorArray) => {
                    fieldErrors.push(...errorArray.map((e) => e.message));
                });
                return fieldErrors;
            } else if (error?.body?.output?.errors && error.body.output.errors.length > 0) {
                return error.body.output.errors.map((e) => e.message);
            } else if (error?.body?.output?.fieldErrors && Object.keys(error.body.output.fieldErrors).length > 0) {
                const fieldErrors = [];
                Object.values(error.body.output.fieldErrors).forEach((errorArray) => {
                    fieldErrors.push(...errorArray.map((e) => e.message));
                });
                return fieldErrors;
            } else if (error.body && typeof error.body.message === 'string') {
                return error.body.message;
            } else if (typeof error.message === 'string') {
                return error.message;
            } else if (typeof error === 'string') {
                return error;
            }

            return error.statusText;
        })

        .reduce((prev, curr) => prev.concat(curr), [])

        .filter((message) => !!message);
}
