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
 * Enforces caller-visible record access at public mutation boundaries. This is
 * required for empty-namespace source deployments where Apex visibility alone
 * cannot separate runtime internals from subscriber code.
 */
public inherited sharing class AgentKernelAccessGuard {
    public static void assertDefinitionReadable(Id definitionId) {
        if (definitionId == null) {
            throw new AgentKernelException.NotFoundException('Agent definition was not found.');
        }
        try {
            if (
                [
                    SELECT COUNT()
                    FROM AgentDefinition__c
                    WHERE Id = :definitionId
                    WITH USER_MODE
                ] != 1
            ) {
                throw new AgentKernelException.NotFoundException('Agent definition was not found.');
            }
        } catch (Exception inaccessible) {
            throw new AgentKernelException.NotFoundException('Agent definition was not found or is inaccessible.');
        }
    }

    public static void assertRunReadable(Id runId) {
        if (runId == null) {
            throw new AgentKernelException.NotFoundException('Agent run was not found.');
        }
        try {
            if (
                [
                    SELECT COUNT()
                    FROM AgentRun__c
                    WHERE Id = :runId
                    WITH USER_MODE
                ] != 1
            ) {
                throw new AgentKernelException.NotFoundException('Agent run was not found.');
            }
        } catch (Exception inaccessible) {
            throw new AgentKernelException.NotFoundException('Agent run was not found or is inaccessible.');
        }
    }

    /**
     * Both the starting user and the user the run's business work executes as
     * must be able to read the anchor, so an agent cannot act on a record for
     * someone who could not see it.
     */
    public static void assertAnchorReadable(Id anchorRecordId, Id businessPrincipalId) {
        if (anchorRecordId == null) {
            return;
        }
        Id startingUserId = UserInfo.getUserId();
        if (!canRead(startingUserId, anchorRecordId)) {
            throw new AgentKernelException.AuthorizationException('The initiating user cannot read the anchor record.');
        }
        if (businessPrincipalId != startingUserId && !canRead(businessPrincipalId, anchorRecordId)) {
            throw new AgentKernelException.AuthorizationException('The execution user cannot read the anchor record.');
        }
    }

    private static Boolean canRead(Id userId, Id recordId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :recordId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return !access.isEmpty() && access[0].HasReadAccess;
    }

    public static void assertInternalDispatchAuthorized() {
        if (!FeatureManagement.checkPermission('AgentKernelInternalDispatch')) {
            throw new AgentKernelException.ConfigurationException('Internal dispatch is not authorized for the current principal.');
        }
    }
}
