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
 * Central authorization boundary for approval decisions. Unknown outcomes
 * are reconciled with Run Control (ExecutionIdentityService.assertCanReconcile).
 * Run visibility and execution identity remain separate mandatory checks.
 */
public without sharing class AgentHumanDecisionGuard {
    private static final String CUSTOM_PERMISSION = 'AgentKernelHumanDecision';

    public static void assertAuthorized() {
        if (!isAuthorized()) {
            throw new AgentKernelException.ConfigurationException('The current user is not authorized to approve Agent Core work.');
        }
    }

    public static Boolean isAuthorized() {
        return FeatureManagement.checkPermission(CUSTOM_PERMISSION);
    }

    /** True when the user is active and holds the Human Decision custom permission. */
    public static Boolean isAuthorizedUser(Id userId) {
        if (userId == null || [SELECT COUNT() FROM User WHERE Id = :userId AND IsActive = TRUE WITH SYSTEM_MODE] == 0) {
            return false;
        }
        return !usersHolding(new Set<Id>{ userId }, new Set<String>{ CUSTOM_PERMISSION }).isEmpty();
    }

    /** Active users among userIds who hold the Human Decision custom permission. */
    public static Set<Id> usersWithDecisionAuthority(Set<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) {
            return new Set<Id>();
        }
        Set<Id> activeUserIds = new Map<Id, User>([SELECT Id FROM User WHERE Id IN :userIds AND IsActive = TRUE WITH SYSTEM_MODE]).keySet();
        return usersHolding(activeUserIds, new Set<String>{ CUSTOM_PERMISSION });
    }

    /** Users among userIds who hold approval decision or relay authority; an execution user must hold neither. */
    public static Set<Id> usersWithApprovalAuthority(Set<Id> userIds) {
        return usersHolding(userIds, new Set<String>{ CUSTOM_PERMISSION, AgentApprovalService.RELAY_PERMISSION });
    }

    private static Set<Id> usersHolding(Set<Id> userIds, Set<String> permissionNames) {
        Set<Id> result = new Set<Id>();
        if (userIds == null || userIds.isEmpty()) {
            return result;
        }
        Datetime now = System.now();
        Set<Id> permissionSetIds = new Set<Id>();
        for (SetupEntityAccess access : [
            SELECT ParentId
            FROM SetupEntityAccess
            WHERE SetupEntityId IN (SELECT Id FROM CustomPermission WHERE DeveloperName IN :permissionNames AND NamespacePrefix = NULL)
            WITH SYSTEM_MODE
        ]) {
            permissionSetIds.add(access.ParentId);
        }
        if (permissionSetIds.isEmpty()) {
            return result;
        }
        for (PermissionSetAssignment assignment : [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE AssigneeId IN :userIds AND PermissionSetId IN :permissionSetIds AND (ExpirationDate = NULL OR ExpirationDate > :now)
            WITH SYSTEM_MODE
        ]) {
            result.add(assignment.AssigneeId);
        }
        return result;
    }
}
