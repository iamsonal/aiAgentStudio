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

trigger AgentCommandIdentityGuard on AgentCommand__c(before insert, before update, before delete) {
    if (Trigger.isDelete) {
        for (AgentCommand__c command : Trigger.old) {
            command.addError('Agent commands are deleted only with their run by the record retention job.');
        }
        return;
    }
    AgentLifecycleInvariantService.prepareCommands(Trigger.new, Trigger.oldMap);
    if (Trigger.isUpdate) {
        AgentIdentityFreezeService.guardCommands(Trigger.oldMap, Trigger.new);
        AgentLifecycleInvariantService.guardCommands(Trigger.oldMap, Trigger.new);
    }
}