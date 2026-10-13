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

@IsTest(SeeAllData=false)
private class AgentEventImmutabilityTest {
    @IsTest
    static void eventUpdateAndDeleteAreRejected() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentEvent__c eventRecord = AgentKernelTestFactory.getEvents(started.runId)[0];

        eventRecord.Summary__c = 'Attempted mutation';
        Database.SaveResult updateResult = Database.update(eventRecord, false);
        System.assertEquals(false, updateResult.isSuccess());
        System.assertEquals(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, updateResult.getErrors()[0].getStatusCode());
        System.assert(updateResult.getErrors()[0].getMessage().contains('immutable'), 'The trigger should explain that events are immutable.');

        Database.DeleteResult deleteResult = Database.delete(eventRecord, false);
        System.assertEquals(false, deleteResult.isSuccess());
        System.assertEquals(StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION, deleteResult.getErrors()[0].getStatusCode());
        System.assert(deleteResult.getErrors()[0].getMessage().contains('immutable'), 'The trigger should reject event deletion.');
        System.assertEquals(2, AgentKernelTestFactory.getEvents(started.runId).size(), 'Rejected mutations must leave the event ledger unchanged.');
    }
}
