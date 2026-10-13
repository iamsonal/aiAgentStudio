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
 * Values Core knows when a tool runs: the run's record, its users, and the
 * date and time. An admin names one as :name in a Fixed Field Value or a
 * Query Records query, and Core fills it in on each call. The model never
 * supplies, sees, or overrides them, so text the agent reads cannot change
 * which record or user they name.
 *
 * A Fixed Field Value can also name one date relative to today:
 *   :today-1d          yesterday
 *   :today+2w          two weeks from today
 *   :today+1y          one year from today (units d, w, m, y)
 *   :endOfMonth        the last day of this month
 *   :startOfWeek+1w    the first day of next week
 *   :endOfMonth-3m     the last day of the month three months ago
 *   :now+4h            four hours from now (units h, d)
 * The offset moves today first, then the date jumps to the start or end of
 * its week, month, quarter, or year. Periods are calendar periods, not
 * fiscal ones. A week starts on the day the principal user's locale starts
 * it. Query Records takes only the plain names, since SOQL has its own date
 * literals.
 *
 * Each value fits only some field types. Tools check the fit when the admin
 * saves, so a bad choice never reaches a run.
 */
public inherited sharing class ToolRunValues {
    /** The run's Anchor Record ID. */
    public static final String ANCHOR_ID = 'anchorId';
    /** The run's Initiating User. */
    public static final String INITIATING_USER_ID = 'initiatingUserId';
    /** The run's Resolved Principal User: the user the run's tools act as. */
    public static final String PRINCIPAL_USER_ID = 'principalUserId';
    /** Today's date in the principal user's time zone. */
    public static final String TODAY = 'today';
    /** The current date and time. */
    public static final String NOW = 'now';

    private static final List<String> NAMES = new List<String>{ ANCHOR_ID, INITIATING_USER_ID, PRINCIPAL_USER_ID, TODAY, NOW };
    /** Dates at the start or end of a calendar period, for Fixed Field Values only. */
    private static final List<String> PERIOD_NAMES = new List<String>{
        'startOfWeek',
        'endOfWeek',
        'startOfMonth',
        'endOfMonth',
        'startOfQuarter',
        'endOfQuarter',
        'startOfYear',
        'endOfYear'
    };
    private static final Pattern NAMED = Pattern.compile('^:([A-Za-z][A-Za-z0-9_]*)(?:([+-])(\\d{1,4})([A-Za-z]))?$');
    private static final Pattern LOOKS_NAMED = Pattern.compile('^:[A-Za-z][A-Za-z0-9_]*(?:[+-][A-Za-z0-9]*)?$');
    private static final Set<String> DATE_UNITS = new Set<String>{ 'd', 'w', 'm', 'y' };
    private static final Set<String> TIME_UNITS = new Set<String>{ 'h', 'd' };

    /** The run value's canonical name, or null when name is not one. */
    public static String canonical(String name) {
        for (String known : NAMES) {
            if (known.equalsIgnoreCase(name == null ? '' : name.trim())) {
                return known;
            }
        }
        return null;
    }

    public static Boolean isRunValue(String name) {
        return canonical(name) != null;
    }

    /**
     * The run value a Fixed Field Value names, such as ":today" or
     * ":endOfMonth+1m", or null for a plain value. A :name that is not a run
     * value is refused, because it is almost always a typo that would
     * otherwise be written as text.
     */
    public static Expression namedBy(Object raw) {
        if (!(raw instanceof String)) {
            return null;
        }
        String text = ((String) raw).trim();
        // Text such as ":)" or ": see notes" is a plain value.
        if (!LOOKS_NAMED.matcher(text).matches()) {
            return null;
        }
        Matcher match = NAMED.matcher(text);
        String name = match.matches() ? canonicalWithPeriods(match.group(1)) : null;
        if (name == null) {
            throw StandardToolSupport.permanent(text + ' is not a run value. Use one of ' + listed() + ', or a date such as :today+3d or :endOfMonth.');
        }
        Expression expression = new Expression(text, name);
        if (match.group(2) != null) {
            String unit = match.group(4).toLowerCase();
            Boolean isDate = name == TODAY || PERIOD_NAMES.contains(name);
            Set<String> units = isDate ? DATE_UNITS : name == NOW ? TIME_UNITS : new Set<String>();
            if (!units.contains(unit)) {
                throw StandardToolSupport.permanent(
                    text +
                        ' is not a run value. ' +
                        (isDate
                            ? 'A date moves by d (days), w (weeks), m (months), or y (years), such as :today+3d.'
                            : name == NOW ? ':now moves by h (hours) or d (days), such as :now+4h.' : ':' + name + ' takes no offset.')
                );
            }
            expression.amount = Integer.valueOf(match.group(3)) * (match.group(2) == '-' ? -1 : 1);
            expression.unit = unit;
        }
        return expression;
    }

    /** A Fixed Field Value that Core fills in on each call: a run value, perhaps moved by an offset. */
    public class Expression {
        /** As the admin wrote it, for messages. */
        public String text { get; private set; }
        /** The canonical run value or period name, such as today or endOfMonth. */
        public String name { get; private set; }
        public Integer amount { get; private set; }
        public String unit { get; private set; }

        Expression(String text, String name) {
            this.text = text;
            this.name = name;
        }

        public Boolean isDate() {
            return name == TODAY || PERIOD_NAMES.contains(name);
        }

        /** Null when the field can hold this value; otherwise the problem to show the admin. */
        public String fitProblem(Schema.DescribeFieldResult field) {
            if (isDate()) {
                return field.getType() == Schema.DisplayType.DATE
                    ? null
                    : text + ' cannot go in ' + field.getName() + '. It is a date, so use it only in a Date field.';
            }
            String problem = ToolRunValues.fitProblem(name, field, null);
            return problem == null ? null : problem.replace(':' + name + ' cannot', text + ' cannot');
        }

        /** The value for this call. */
        public Object resolveFor(AgentKernelModels.ToolRequest request, Schema.DescribeFieldResult field) {
            if (isDate()) {
                return dateFor(Date.today());
            }
            if (name == NOW) {
                Datetime current = Datetime.now();
                return amount == null ? current : unit == 'h' ? current.addHours(amount) : current.addDays(amount);
            }
            return ToolRunValues.resolveFor(name, request, field);
        }

        /** Moves today by the offset, then jumps to the start or end of the period. */
        @TestVisible
        Date dateFor(Date fromDay) {
            Date moved = fromDay;
            if (amount != null) {
                if (unit == 'd') {
                    moved = fromDay.addDays(amount);
                } else if (unit == 'w') {
                    moved = fromDay.addDays(amount * 7);
                } else if (unit == 'm') {
                    moved = fromDay.addMonths(amount);
                } else {
                    moved = fromDay.addMonths(amount * 12);
                }
            }
            if (name == TODAY) {
                return moved;
            }
            Date start;
            Integer months;
            if (name.endsWith('Week')) {
                start = moved.toStartOfWeek();
                return name.startsWith('start') ? start : start.addDays(6);
            } else if (name.endsWith('Month')) {
                start = moved.toStartOfMonth();
                months = 1;
            } else if (name.endsWith('Quarter')) {
                start = Date.newInstance(moved.year(), ((moved.month() - 1) / 3) * 3 + 1, 1);
                months = 3;
            } else {
                start = Date.newInstance(moved.year(), 1, 1);
                months = 12;
            }
            return name.startsWith('start') ? start : start.addMonths(months).addDays(-1);
        }
    }

    private static String canonicalWithPeriods(String name) {
        String plain = canonical(name);
        if (plain != null) {
            return plain;
        }
        for (String period : PERIOD_NAMES) {
            if (period.equalsIgnoreCase(name)) {
                return period;
            }
        }
        return null;
    }

    /**
     * Null when the field can hold the run value; otherwise the problem to
     * show the admin. ownerType is the object that owns the field, needed only
     * for an Id field; pass null otherwise.
     */
    public static String fitProblem(String name, Schema.DescribeFieldResult field, Schema.SObjectType ownerType) {
        Schema.DisplayType type = field.getType();
        String label = ':' + name + ' cannot go in ' + field.getName() + '. ';
        if (name == TODAY) {
            return type == Schema.DisplayType.DATE ? null : label + 'It is a date, so use it only in a Date field.';
        }
        if (name == NOW) {
            return type == Schema.DisplayType.DATETIME ? null : label + 'It is a date and time, so use it only in a Date/Time field.';
        }
        if (name == ANCHOR_ID) {
            return type == Schema.DisplayType.REFERENCE ||
                type == Schema.DisplayType.ID
                ? null
                : label + 'It is a record ID, so use it in Id or a lookup field.';
        }
        Boolean holdsUser = type == Schema.DisplayType.ID
            ? ownerType == User.SObjectType
            : type == Schema.DisplayType.REFERENCE && field.getReferenceTo().contains(User.SObjectType);
        return holdsUser ? null : label + 'It is a user ID, so use it in a lookup field that can point to a user, such as OwnerId.';
    }

    /**
     * The run value for this call: an Id, a Date, or a Datetime. Fails as a
     * permanent error when the run does not have it, such as :anchorId on a
     * run that was not started on a record.
     */
    public static Object resolve(String name, AgentKernelModels.ToolRequest request) {
        if (name == TODAY) {
            return Date.today();
        }
        if (name == NOW) {
            return Datetime.now();
        }
        AgentKernelModels.ExecutionPrincipal principal = request == null ? null : request.principal;
        Id value;
        String missing;
        if (name == ANCHOR_ID) {
            value = principal == null ? null : principal.anchorRecordId;
            missing = 'This tool uses :anchorId, the run\'s record, but the run was not started on a record.';
        } else if (name == INITIATING_USER_ID) {
            value = principal == null ? null : principal.initiatingUserId;
            missing = 'This tool uses :initiatingUserId, but the run has no Initiating User.';
        } else if (name == PRINCIPAL_USER_ID) {
            value = principal == null ? null : principal.resolvedPrincipalUserId;
            missing = 'This tool uses :principalUserId, but the run has no Resolved Principal User yet.';
        } else {
            throw StandardToolSupport.permanent(':' + name + ' is not a run value. Use one of ' + listed() + '.');
        }
        if (value == null) {
            throw StandardToolSupport.permanent(missing);
        }
        return value;
    }

    /**
     * The run value for a field, checked against the record the field can
     * point to. Used for Fixed Field Values, where the field is known.
     */
    public static Object resolveFor(String name, AgentKernelModels.ToolRequest request, Schema.DescribeFieldResult field) {
        Object value = resolve(name, request);
        if (name == ANCHOR_ID && field.getType() == Schema.DisplayType.REFERENCE && !field.getReferenceTo().contains(((Id) value).getSObjectType())) {
            throw StandardToolSupport.permanent(
                field.getName() +
                    ' cannot point to the run\'s record, which is a ' +
                    ((Id) value).getSObjectType().getDescribe().getName() +
                    '. Run this tool on a matching record.'
            );
        }
        return value;
    }

    private static String listed() {
        List<String> named = new List<String>();
        for (String name : NAMES) {
            named.add(':' + name);
        }
        return String.join(named, ', ');
    }
}
