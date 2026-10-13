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
 * Answers who a same-org Named Credential signs in as, for Agent Execution
 * Identity verification. It reports only the caller's own user Id and two
 * permission checks; it reads and changes no records.
 */
@RestResource(urlMapping='/agent-core/v1/whoami')
global without sharing class ExecutionIdentityProbeRest {
    global class Probe {
        global Id userId;
        /** True when this user holds Agent Kernel Internal Dispatch, which the loopback requires. */
        global Boolean mayDispatch;
        /** True when this user holds Human Decision or Approval Relay, which an execution user must not. */
        global Boolean holdsApprovalAuthority;
    }

    @HttpGet
    global static Probe whoAmI() {
        Probe result = new Probe();
        result.userId = UserInfo.getUserId();
        result.mayDispatch = FeatureManagement.checkPermission('AgentKernelInternalDispatch');
        result.holdsApprovalAuthority = AgentHumanDecisionGuard.isAuthorized() || AgentApprovalService.isRelayAuthorized();
        return result;
    }
}
