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

/**
 * Values Core fills in each time a tool runs (ToolRunValues in Pluto Core).
 * The admin picks one as a Fixed Field Value; the model never sets them.
 * Each fits only the field types listed in fits; a user value also needs a
 * lookup that can point to a user. Core checks the fit again on save.
 */
export const RUN_VALUES = [
    { value: ':anchorId', label: ':anchorId', subtitle: "The run's record (Anchor Record ID)", icon: 'utility:record', fits: ['reference', 'id'] },
    {
        value: ':initiatingUserId',
        label: ':initiatingUserId',
        subtitle: 'Initiating User: the user who started the run',
        icon: 'utility:user',
        fits: ['reference'],
        user: true
    },
    {
        value: ':principalUserId',
        label: ':principalUserId',
        subtitle: "Resolved Principal User: the user the run's tools act as",
        icon: 'utility:identity',
        fits: ['reference'],
        user: true
    },
    { value: ':today', label: ':today', subtitle: "Today's date", icon: 'utility:date_input', fits: ['date'] },
    { value: ':now', label: ':now', subtitle: 'The current date and time', icon: 'utility:clock', fits: ['datetime'] }
];

/** The run values that fit a field option; empty for an unknown field or a type no run value fits. */
export function runValueOptions(field) {
    const type = (field?.meta?.type || field?.fieldType || field?.dataType || '').toLowerCase();
    return RUN_VALUES.filter((runValue) => runValue.fits.includes(type) && (!runValue.user || field?.pointsToUser === true)).map(
        ({ fits, user, ...option }) => option
    );
}

export const DATE_UNITS = [
    { value: 'd', label: 'Days' },
    { value: 'w', label: 'Weeks' },
    { value: 'm', label: 'Months' },
    { value: 'y', label: 'Years' }
];

export const TIME_UNITS = [
    { value: 'h', label: 'Hours' },
    { value: 'd', label: 'Days' }
];

/** Fixed Field Values only: the start or end of a calendar period. Core reads the same names (ToolRunValues.Expression). */
const PERIOD_NAMES = ['startOfWeek', 'endOfWeek', 'startOfMonth', 'endOfMonth', 'startOfQuarter', 'endOfQuarter', 'startOfYear', 'endOfYear'];

const EXPRESSION = /^:([A-Za-z]+)(?:([+-])(\d{1,4})([A-Za-z]))?$/;

/**
 * The parts of a relative date or time, such as :endOfMonth+1m, or null
 * when the text is not one: { base, amount, unit, period }. base is today
 * or now; amount is signed.
 */
export function parseRelative(text) {
    const match = EXPRESSION.exec(typeof text === 'string' ? text.trim() : '');
    if (!match) {
        return null;
    }
    const name = match[1].toLowerCase();
    const period = PERIOD_NAMES.find((candidate) => candidate.toLowerCase() === name);
    const base = name === 'now' ? 'now' : name === 'today' || period ? 'today' : null;
    if (!base) {
        return null;
    }
    const amount = match[2] ? Number(match[3]) * (match[2] === '-' ? -1 : 1) : 0;
    return { base, amount, unit: match[4] ? match[4].toLowerCase() : base === 'now' ? 'h' : 'd', period: period || '' };
}

/** The stored text for a relative date or time; the inverse of parseRelative. */
export function relativeText({ base, amount, unit, period }) {
    const name = base === 'now' ? 'now' : period || 'today';
    const count = Math.trunc(Number(amount) || 0);
    return ':' + name + (count ? (count > 0 ? '+' : '-') + Math.abs(count) + unit : '');
}
