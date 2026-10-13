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

/** Read-only validation of an agent definition and its active configuration. */
global inherited sharing class AgentConfigurationValidationService {
    global class ValidationRequest {
        global Id definitionId { get; set; }
        global String developerName { get; set; }
        global ValidationRequest() {
        }
    }

    global class ValidationIssue {
        global String severity { get; set; }
        global String code { get; set; }
        global String path { get; set; }
        global String message { get; set; }
        global ValidationIssue() {
        }
    }

    global class ValidationReport {
        global Id definitionId { get; set; }
        global String developerName { get; set; }
        global Boolean isValid { get; set; }
        global List<ValidationIssue> issues { get; set; }
        global ValidationReport() {
        }
    }

    global static ValidationReport validate(ValidationRequest request) {
        validateRequest(request);
        List<AgentDefinition__c> definitions;
        if (request.definitionId != null) {
            definitions = queryById(request.definitionId);
        } else {
            definitions = queryByName(request.developerName.trim());
        }
        if (definitions.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent definition was not found or is inaccessible.');
        }
        AgentDefinition__c definition = definitions[0];
        ValidationReport report = new ValidationReport();
        report.definitionId = definition.Id;
        report.developerName = definition.DeveloperName__c;
        report.issues = new List<ValidationIssue>();

        List<AgentTool__c> tools = queryTools(definition.Id);
        List<AgentContextProvider__c> contextProviders = queryContextProviders(definition.Id);
        List<AgentConfigurationValidator.Finding> findings;
        Exception validationFailure;
        ExtensionExecutionGuard.Boundary validationBoundary = ExtensionExecutionGuard.open();
        try {
            findings = AgentConfigurationValidator.collectErrors(definition, tools, contextProviders);
        } catch (Exception caughtFailure) {
            validationFailure = caughtFailure;
        }
        ExtensionExecutionGuard.Result validationIsolation = ExtensionExecutionGuard.close(validationBoundary);
        if (
            validationIsolation.performedDml ||
            validationIsolation.performedCallout ||
            validationIsolation.performedProhibitedAsync() ||
            validationFailure instanceof CalloutException
        ) {
            error(report, 'EXTENSION_INITIALIZATION_SIDE_EFFECT', 'AgentDefinition.Extensions', 'Extension initialization must remain query-only.');
        } else if (validationFailure != null) {
            throw validationFailure;
        }
        for (AgentConfigurationValidator.Finding finding : findings == null ? new List<AgentConfigurationValidator.Finding>() : findings) {
            error(report, finding.code, finding.path, finding.message);
        }

        try {
            if (ExecutionIdentityService.usesIdentity(definition)) {
                ExecutionIdentityService.snapshotForStart(definition.ExecutionIdentity__c);
            }
        } catch (Exception invalidLoopbackSetting) {
            error(report, 'EXECUTION_IDENTITY_UNUSABLE', 'AgentDefinition.ExecutionIdentity', safe(invalidLoopbackSetting.getMessage()));
        }
        User executionUser = ToolExecutionUserAccess.executionUsers(new Set<Id>{ definition.Id }).get(definition.Id);
        for (AgentTool__c tool : tools) {
            String accessProblem = ToolExecutionUserAccess.problem(tool, executionUser);
            if (accessProblem != null) {
                error(report, 'EXECUTION_USER_ACCESS_MISSING', 'AgentTool[' + tool.DeveloperName__c + ']', accessProblem);
            }
        }
        if (tools.isEmpty()) {
            warning(report, 'NO_ACTIVE_TOOLS', 'AgentDefinition.Tools', 'No active tools are configured; a tool-free agent is valid.');
        }
        if (ExecutionIdentityService.usesIdentity(definition)) {
            for (AgentTool__c tool : tools) {
                if (isUnscopedUpdate(tool)) {
                    warning(
                        report,
                        'UNSCOPED_RECORD_UPDATE',
                        'AgentTool[' + tool.DeveloperName__c + '].ImplementationConfiguration',
                        'This Update Record tool may change any record the execution user can edit, chosen by the model. Text in records or emails can steer ' +
                        'that choice. Check Anchor Record Only, or check Always Require Approval.'
                    );
                }
            }
        }
        warning(
            report,
            'NAMED_CREDENTIAL_ACCESS_NOT_PREFLIGHTED',
            'AgentModel.NamedCredential',
            'Named Credential existence and runtime principal access are not portable Apex preflight checks.'
        );
        AgentExecutionPolicyService.Policy executionPolicy = AgentExecutionPolicyService.resolve(definition);
        if (PayloadProtectionService.normalizeMode(executionPolicy.payloadRetentionMode) == PayloadProtectionService.MODE_FULL) {
            warning(
                report,
                'FULL_PAYLOAD_RETENTION',
                'AgentDataPolicy.OrgDefaults.PayloadRetentionMode',
                'Full payload retention may persist sensitive content.'
            );
        }
        report.issues.sort(new IssueComparator());
        report.isValid = true;
        for (ValidationIssue issue : report.issues) {
            if (issue.severity == 'Error') {
                report.isValid = false;
                break;
            }
        }
        return report;
    }

    /** An Update Record tool without approval whose record the model picks freely. */
    private static Boolean isUnscopedUpdate(AgentTool__c tool) {
        AgentToolType__mdt toolType = AgentToolTypeService.toolType(tool);
        if (
            tool.RequiresApproval__c == true ||
            toolType == null ||
            toolType.ToolClass__c == null ||
            toolType.ToolClass__c.trim() != 'StandardUpdateRecordTool'
        ) {
            return false;
        }
        try {
            return !StandardToolSupport.anchorRecordOnly(StandardToolSupport.configuration(tool.ImplementationConfiguration__c));
        } catch (Exception unreadable) {
            return false;
        }
    }

    private static void validateRequest(ValidationRequest request) {
        if (request == null || (request.definitionId == null) == String.isBlank(request == null ? null : request.developerName)) {
            throw new AgentKernelException.ConfigurationException('Specify exactly one definitionId or developerName.');
        }
    }

    private static List<AgentDefinition__c> queryById(Id definitionId) {
        return [
            SELECT
                Id,
                DeveloperName__c,
                IsActive__c,
                ExecutionIdentity__c,
                Instructions__c,
                Model__c,
                MaxModelCalls__c,
                MaxToolCalls__c,
                MaxTotalTokens__c,
                MaxRetries__c,
                MaxModelRequestCharacters__c,
                ModelTimeoutSeconds__c,
                TranscriptTurnLimit__c,
                ReplyWindowHours__c,
                OutputSchema__c,
                ToolAuthorizationPolicyClass__c
            FROM AgentDefinition__c
            WHERE Id = :definitionId
            WITH USER_MODE
            LIMIT 1
        ];
    }
    private static List<AgentDefinition__c> queryByName(String developerName) {
        return [
            SELECT
                Id,
                DeveloperName__c,
                IsActive__c,
                ExecutionIdentity__c,
                Instructions__c,
                Model__c,
                MaxModelCalls__c,
                MaxToolCalls__c,
                MaxTotalTokens__c,
                MaxRetries__c,
                MaxModelRequestCharacters__c,
                ModelTimeoutSeconds__c,
                TranscriptTurnLimit__c,
                ReplyWindowHours__c,
                OutputSchema__c,
                ToolAuthorizationPolicyClass__c
            FROM AgentDefinition__c
            WHERE DeveloperName__c = :developerName
            WITH USER_MODE
            LIMIT 1
        ];
    }
    private static List<AgentTool__c> queryTools(Id definitionId) {
        Integer queryLimit = AgentConfigService.MAX_ACTIVE_TOOL_COUNT + 1;
        return [
            SELECT
                Id,
                DeveloperName__c,
                Description__c,
                ToolType__c,
                ImplementationConfiguration__c,
                InputSchema__c,
                RequiresApproval__c,
                AllowedSensitiveDataCategories__c
            FROM AgentTool__c
            WHERE AgentDefinition__c = :definitionId AND IsActive__c = TRUE
            WITH USER_MODE
            ORDER BY DeveloperName__c ASC, Id ASC
            LIMIT :queryLimit
        ];
    }

    private static List<AgentContextProvider__c> queryContextProviders(Id definitionId) {
        return [
            SELECT
                Id,
                AgentDefinition__c,
                DeveloperName__c,
                Description__c,
                ImplementationType__c,
                ImplementationReference__c,
                ImplementationConfiguration__c,
                ContextSubject__c,
                ObjectApiName__c,
                FieldSetName__c,
                SortOrder__c,
                IsActive__c
            FROM AgentContextProvider__c
            WHERE AgentDefinition__c = :definitionId AND IsActive__c = TRUE
            WITH USER_MODE
            ORDER BY SortOrder__c ASC NULLS LAST, DeveloperName__c ASC
        ];
    }

    private static void error(ValidationReport report, String code, String path, String message) {
        issue(report, 'Error', code, path, message);
    }
    private static void warning(ValidationReport report, String code, String path, String message) {
        issue(report, 'Warning', code, path, message);
    }
    private static void issue(ValidationReport report, String severity, String code, String path, String message) {
        ValidationIssue issue = new ValidationIssue();
        issue.severity = severity;
        issue.code = code;
        issue.path = path;
        issue.message = safe(message);
        report.issues.add(issue);
    }
    private static String safe(String message) {
        String result = String.isBlank(message) ? 'Configuration is invalid.' : message.replace('\r', ' ').replace('\n', ' ').trim();
        return result.length() > 255 ? result.substring(0, 255) : result;
    }
    private class IssueComparator implements Comparator<ValidationIssue> {
        public Integer compare(ValidationIssue left, ValidationIssue right) {
            String leftKey = left.severity + '|' + left.code + '|' + left.path;
            String rightKey = right.severity + '|' + right.code + '|' + right.path;
            return leftKey.compareTo(rightKey);
        }
    }
}
