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
 * Transaction-cached access to Salesforce native field classifications.
 * This module caches metadata only; it never retains record values.
 */
public inherited sharing class SchemaFieldClassificationService {
    private static final Set<String> SENSITIVE_LEVELS = new Set<String>{ 'confidential', 'restricted', 'missioncritical' };
    private static final Set<String> SENSITIVE_COMPLIANCE_GROUPS = new Set<String>{ 'ccpa', 'coppa', 'gdpr', 'hipaa', 'pci', 'personalinfo', 'pii' };
    private static Map<String, Set<String>> sensitiveFieldsByObject = new Map<String, Set<String>>();
    @TestVisible
    private static Map<String, Set<String>> sensitiveFieldOverrides = new Map<String, Set<String>>();

    public static Boolean isSensitive(String objectApiName, String fieldApiName) {
        if (String.isBlank(objectApiName) || String.isBlank(fieldApiName)) {
            return false;
        }
        String objectKey = objectApiName.trim().toLowerCase();
        if (sensitiveFieldOverrides.containsKey(objectKey)) {
            return sensitiveFieldOverrides.get(objectKey).contains(fieldApiName.trim().toLowerCase());
        }
        load(objectApiName.trim(), objectKey);
        return sensitiveFieldsByObject.get(objectKey).contains(fieldApiName.trim().toLowerCase());
    }

    private static void load(String objectApiName, String objectKey) {
        if (sensitiveFieldsByObject.containsKey(objectKey)) {
            return;
        }
        Set<String> sensitiveFields = new Set<String>();
        for (
            SObject fieldMetadata : Database.query(
                'SELECT QualifiedApiName, SecurityClassification, ComplianceGroup ' +
                'FROM FieldDefinition WHERE EntityDefinition.QualifiedApiName = :objectApiName',
                AccessLevel.USER_MODE
            )
        ) {
            String sensitivity = stringValue(fieldMetadata.get('SecurityClassification'));
            String compliance = stringValue(fieldMetadata.get('ComplianceGroup'));
            if (SENSITIVE_LEVELS.contains(normalize(sensitivity)) || hasSensitiveCompliance(compliance)) {
                sensitiveFields.add(normalize(stringValue(fieldMetadata.get('QualifiedApiName'))));
            }
        }
        sensitiveFieldsByObject.put(objectKey, sensitiveFields);
    }

    private static Boolean hasSensitiveCompliance(String compliance) {
        for (String complianceGroup : normalize(compliance).split(';')) {
            if (SENSITIVE_COMPLIANCE_GROUPS.contains(complianceGroup.trim())) {
                return true;
            }
        }
        return false;
    }

    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static String normalize(String value) {
        return String.isBlank(value) ? '' : value.trim().toLowerCase();
    }

    @TestVisible
    private static void clearCache() {
        sensitiveFieldsByObject.clear();
        sensitiveFieldOverrides.clear();
    }
}
