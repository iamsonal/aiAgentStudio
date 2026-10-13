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
 * Class-name options for Pluto configuration picklists.
 *
 * UI aid only: enumerates concrete Apex classes implementing a Core
 * extension seam so admins pick instead of typing class names. Read-only,
 * no DML. The interface allowlist keeps the Tooling query fail-closed;
 * callers cannot enumerate arbitrary interfaces.
 */
public with sharing class PlutoImplementationDiscoveryService {
    private static final Set<String> ALLOWED_INTERFACES = new Set<String>{ 'IModelProvider', 'IContextProvider', 'ITool', 'IToolAuthorizationPolicy' };

    public class ClassOption {
        @AuraEnabled
        public String value { get; set; }
        @AuraEnabled
        public String label { get; set; }

        public ClassOption(String value, String label) {
            this.value = value;
            this.label = label;
        }
    }

    public class ModelOption {
        @AuraEnabled
        public String value { get; set; }
        @AuraEnabled
        public String label { get; set; }

        public ModelOption(AgentModel__mdt model) {
            value = model.DeveloperName;
            label = model.MasterLabel + ' (' + model.ModelIdentifier__c + ')';
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<ClassOption> getClassOptions(String interfaceName) {
        if (String.isBlank(interfaceName) || !ALLOWED_INTERFACES.contains(interfaceName.trim())) {
            throw new AuraHandledException('Unsupported interface: ' + interfaceName);
        }
        String normalized = interfaceName.trim();
        List<ClassOption> options = new List<ClassOption>();
        for (ApexTypeImplementor implementor : [
            SELECT ClassName
            FROM ApexTypeImplementor
            WHERE InterfaceName = :normalized AND IsConcrete = TRUE
            WITH SYSTEM_MODE
            ORDER BY ClassName ASC
        ]) {
            options.add(new ClassOption(implementor.ClassName, implementor.ClassName));
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<ModelOption> getModelOptions() {
        List<ModelOption> options = new List<ModelOption>();
        for (AgentModel__mdt model : AgentModelService.activeModels()) {
            options.add(new ModelOption(model));
        }
        options.sort(new ModelOptionOrder());
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<ClassOption> getNamedCredentialOptions() {
        List<ClassOption> options = new List<ClassOption>();
        for (NamedCredential credential : [SELECT DeveloperName, MasterLabel FROM NamedCredential WITH SYSTEM_MODE ORDER BY MasterLabel LIMIT 500]) {
            options.add(new ClassOption(credential.DeveloperName, credential.MasterLabel + ' (' + credential.DeveloperName + ')'));
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<ClassOption> getApproverQueueOptions() {
        List<ClassOption> options = new List<ClassOption>();
        // Setup discovery only; Core remains responsible for assignment and decision authority.
        for (QueueSobject supported : [
            SELECT Queue.DeveloperName, Queue.Name
            FROM QueueSobject
            WHERE Queue.Type = 'Queue' AND SobjectType = 'AgentApproval__c'
            WITH SYSTEM_MODE
            ORDER BY Queue.Name, Queue.DeveloperName
            LIMIT 500
        ]) {
            options.add(new ClassOption(supported.Queue.DeveloperName, supported.Queue.Name + ' (' + supported.Queue.DeveloperName + ')'));
        }
        return options;
    }

    @AuraEnabled(cacheable=true)
    public static List<ClassOption> getFieldSetOptions(String objectApiName) {
        List<ClassOption> options = new List<ClassOption>();
        if (String.isBlank(objectApiName)) {
            return options;
        }
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectApiName.trim());
        if (objectType == null || !objectType.getDescribe().isQueryable() || !objectType.getDescribe().isAccessible()) {
            return options;
        }
        for (Schema.FieldSet fieldSet : objectType.getDescribe().fieldSets.getMap().values()) {
            options.add(new ClassOption(fieldSet.getName(), fieldSet.getLabel() + ' (' + fieldSet.getName() + ')'));
        }
        options.sort(new ClassOptionOrder());
        return options;
    }

    private class ClassOptionOrder implements System.Comparator<ClassOption> {
        public Integer compare(ClassOption left, ClassOption right) {
            return left.label.compareTo(right.label);
        }
    }

    private class ModelOptionOrder implements System.Comparator<ModelOption> {
        public Integer compare(ModelOption left, ModelOption right) {
            return left.label.compareTo(right.label);
        }
    }
}
