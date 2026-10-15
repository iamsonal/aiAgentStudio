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

/** Binds a human approval to the exact pending input and executable tool configuration. */
public inherited sharing class ToolApprovalFingerprint {
    public static String compute(AgentCommand__c command, AgentTool__c tool, AgentDefinition__c definition) {
        String approvalMode = AgentApprovalService.mode(tool);
        List<String> approvedSurface = new List<String>{
            String.valueOf(command.Id),
            command.OperationKey__c,
            command.Input__c,
            String.valueOf(tool.Id),
            tool.DeveloperName__c,
            AgentToolTypeService.bindingHash(tool),
            tool.InputSchema__c,
            approvalMode,
            tool.AllowedSensitiveDataCategories__c,
            approvalMode == AgentKernelModels.APPROVAL_DECIDED_BY_POLICY ? definition.ToolAuthorizationPolicyClass__c : null
        };
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(JSON.serialize(approvedSurface))));
    }
}
