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

/** Agent HITL fixes for the Pluto Overview, reached by name so Pluto deploys without Agent HITL. */
public with sharing class PlutoHitlController {
    private static final String OPERATIONS_CLASS = 'AgentHitlOperations';
    @TestVisible
    private static System.Callable operationsForTest;

    /** Re-sends every open failed approval relay; returns how many were sent. */
    @AuraEnabled
    public static Integer retryApprovalRelays() {
        try {
            System.Callable operations = Test.isRunningTest() && operationsForTest != null ? operationsForTest : named();
            if (operations == null) {
                throw new AuraHandledException('Agent HITL is not installed in this org.');
            }
            return (Integer) operations.call('retryRelays', null);
        } catch (Exception failure) {
            AuraHandledException error = new AuraHandledException(failure.getMessage());
            error.setMessage(failure.getMessage());
            throw error;
        }
    }

    private static System.Callable named() {
        Type operationsType = Type.forName(OPERATIONS_CLASS);
        return operationsType == null ? null : (System.Callable) operationsType.newInstance();
    }
}
