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

@IsTest
private class ToolRunValuesTest {
    private static final Date JAN_31 = Date.newInstance(2026, 1, 31);

    private static Date dateOf(String text, Date fromDay) {
        return ToolRunValues.namedBy(text).dateFor(fromDay);
    }

    @IsTest
    static void movesTodayByDaysWeeksMonthsAndYears() {
        System.assertEquals(JAN_31, dateOf(':today', JAN_31));
        System.assertEquals(Date.newInstance(2026, 1, 30), dateOf(':today-1d', JAN_31), 'Yesterday.');
        System.assertEquals(Date.newInstance(2026, 2, 14), dateOf(':today+2w', JAN_31));
        System.assertEquals(Date.newInstance(2026, 2, 28), dateOf(':today+1m', JAN_31), 'A month on from January 31 is the last day of February.');
        System.assertEquals(Date.newInstance(2027, 1, 31), dateOf(':TODAY+1Y', JAN_31), 'Names and units ignore case.');
    }

    @IsTest
    static void jumpsToTheStartOrEndOfAPeriodAfterMoving() {
        System.assertEquals(Date.newInstance(2026, 1, 1), dateOf(':startOfMonth', JAN_31));
        System.assertEquals(Date.newInstance(2026, 2, 28), dateOf(':endOfMonth+1m', JAN_31));
        System.assertEquals(Date.newInstance(2028, 2, 29), dateOf(':endOfMonth+25m', JAN_31), 'A leap year February ends on the 29th.');
        System.assertEquals(Date.newInstance(2025, 12, 31), dateOf(':endOfMonth-1m', JAN_31), 'End of last month.');
        System.assertEquals(Date.newInstance(2026, 3, 31), dateOf(':endOfQuarter', JAN_31));
        System.assertEquals(Date.newInstance(2026, 4, 1), dateOf(':startOfQuarter+1m', Date.newInstance(2026, 3, 15)));
        System.assertEquals(Date.newInstance(2026, 1, 1), dateOf(':startOfYear', JAN_31));
        System.assertEquals(Date.newInstance(2025, 12, 31), dateOf(':endOfYear-1y', JAN_31));
    }

    @IsTest
    static void aWeekStartsWhereTheUsersLocaleStartsIt() {
        Date start = JAN_31.toStartOfWeek();
        System.assertEquals(start, dateOf(':startOfWeek', JAN_31));
        System.assertEquals(start.addDays(6), dateOf(':endOfWeek', JAN_31));
        System.assertEquals(start.addDays(7), dateOf(':startOfWeek+1w', JAN_31), 'Start of next week.');
    }

    @IsTest
    static void plainTextIsNotARunValue() {
        System.assertEquals(null, ToolRunValues.namedBy('Created by the agent'));
        System.assertEquals(null, ToolRunValues.namedBy(':)'));
        System.assertEquals(null, ToolRunValues.namedBy(': see notes'));
        System.assertEquals(null, ToolRunValues.namedBy(3));
    }

    @IsTest
    static void refusesWhatItCannotRead() {
        assertRefused(':tomorrow', 'is not a run value');
        assertRefused(':endOfFortnight', 'is not a run value');
        assertRefused(':today+3x', 'd (days), w (weeks)');
        assertRefused(':today+3h', 'd (days), w (weeks)');
        assertRefused(':now+1m', 'h (hours) or d (days)');
        assertRefused(':anchorId+1d', 'takes no offset');
    }

    @IsTest
    static void aDateFitsOnlyADateFieldAndNowMovesByHours() {
        ToolRunValues.Expression endOfMonth = ToolRunValues.namedBy(':endOfMonth');
        System.assertEquals(null, endOfMonth.fitProblem(Task.ActivityDate.getDescribe()));
        System.assert(endOfMonth.fitProblem(Task.Subject.getDescribe()).startsWith(':endOfMonth cannot go in Subject.'));
        System.assert(ToolRunValues.namedBy(':now+4h').fitProblem(Account.Name.getDescribe()).startsWith(':now+4h cannot go in Name.'));

        Datetime before = Datetime.now().addHours(4);
        Datetime value = (Datetime) ToolRunValues.namedBy(':now+4h').resolveFor(null, Event.ActivityDateTime.getDescribe());
        System.assert(value >= before && value <= Datetime.now().addHours(4), 'Four hours from now.');
    }

    private static void assertRefused(String text, String fragment) {
        try {
            ToolRunValues.namedBy(text);
            System.assert(false, text + ' must be refused.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains(fragment), expected.getMessage());
        }
    }
}
