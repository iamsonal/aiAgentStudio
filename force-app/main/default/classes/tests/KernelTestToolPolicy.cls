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
global with sharing class KernelTestToolPolicy implements IToolAuthorizationPolicy {
    global static AgentKernelModels.ToolAuthorizationDecision configuredDecision = AgentKernelModels.ToolAuthorizationDecision.Allow;
    global static String configuredReason = 'Approval required by test policy.';
    global static Id configuredApproverUserId;
    global static String configuredApproverQueue;
    global static Boolean performDml = false;
    global static Boolean throwUnexpected = false;
    global static AgentKernelModels.ToolAuthorizationRequest lastRequest;
    /** Tools denied whatever configuredDecision says. */
    global static Set<String> deniedToolNames = new Set<String>();

    global AgentKernelModels.ToolAuthorizationResponse evaluate(AgentKernelModels.ToolAuthorizationRequest request) {
        lastRequest = request;
        if (performDml) {
            insert new Account(Name = 'Tool policy must remain query-only');
        }
        if (throwUnexpected) {
            throw new AgentKernelException.ConfigurationException('Unexpected policy failure.');
        }
        if (deniedToolNames.contains(request.toolName) || configuredDecision == AgentKernelModels.ToolAuthorizationDecision.Deny) {
            return request.deny(configuredReason);
        }
        if (configuredDecision != AgentKernelModels.ToolAuthorizationDecision.RequireApproval) {
            return request.allow();
        }
        AgentKernelModels.ToolApprovalResponse held = request.requireApproval(configuredReason).withTimeoutMinutes(60);
        if (configuredApproverQueue != null) {
            held.byQueue(configuredApproverQueue);
        }
        if (configuredApproverUserId != null) {
            held.byUser(configuredApproverUserId);
        }
        return held;
    }
}
