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
 * Server side of the tool editor. A tool is its Tool Type, its settings
 * (Implementation Configuration, with the admin's input edits under
 * inputOverrides), and, only for a tool type that does not build its
 * inputs, a hand-written Input Schema. Core builds, checks, and applies
 * everything; this class only previews a draft and saves it once, in user
 * mode, so Core checks the final record once.
 */
public with sharing class ToolAuthoringController {
    private static final Integer MAX_SEARCH_RESULTS = 25;
    private static final Integer MAX_WRITABLE_FIELDS = 30;
    private static final Pattern SLDS_ICON_PATH = Pattern.compile('.*/(standard|custom)/([a-z0-9_]+?)(?:_\\d+)?\\.(?:svg|png)$');
    /** Header fields the page may set; the editor owns the type, settings, and schema. */
    private static final Set<String> EDITABLE_TOOL_FIELDS = new Set<String>{
        'Name',
        'AgentDefinition__c',
        'DeveloperName__c',
        'Description__c',
        'IsActive__c',
        'SortOrder__c',
        'ApprovalMode__c',
        'ApproverType__c',
        'ApproverUser__c',
        'ApproverQueue__c',
        'ApprovalRoute__c',
        'ApprovalTimeoutMinutes__c',
        'ApprovalExpiryAction__c',
        'AllowedSensitiveDataCategories__c'
    };

    public class Option implements Comparable {
        @AuraEnabled
        public String value { get; set; }
        @AuraEnabled
        public String label { get; set; }
        @AuraEnabled
        public String meta { get; set; }
        @AuraEnabled
        public String iconName { get; set; }

        public Integer compareTo(Object other) {
            Option peer = (Option) other;
            String left = label == null ? '' : label.toLowerCase();
            String right = peer == null || peer.label == null ? '' : peer.label.toLowerCase();
            return left.compareTo(right);
        }
    }

    public class PicklistOption {
        @AuraEnabled
        public String label { get; set; }
        @AuraEnabled
        public String value { get; set; }
    }

    public class FieldOption implements Comparable {
        @AuraEnabled
        public String value { get; set; }
        @AuraEnabled
        public String label { get; set; }
        @AuraEnabled
        public String subtitle { get; set; }
        @AuraEnabled
        public String description { get; set; }
        @AuraEnabled
        public String dataType { get; set; }
        @AuraEnabled
        public String fieldType { get; set; }
        @AuraEnabled
        public Boolean required { get; set; }
        @AuraEnabled
        public Boolean createable { get; set; }
        @AuraEnabled
        public Boolean updateable { get; set; }
        @AuraEnabled
        public Boolean isPicklist { get; set; }
        @AuraEnabled
        public List<PicklistOption> picklistValues { get; set; }
        @AuraEnabled
        public String referenceTo { get; set; }
        /** True for a lookup that can point to a user, such as OwnerId, where a user run value fits. */
        @AuraEnabled
        public Boolean pointsToUser { get; set; }
        /** Set only for a lookup a query may read through: one target object, not a Pluto Core object. */
        @AuraEnabled
        public String relationshipName { get; set; }
        /** How many objects a lookup can point to; a lookup to one object gets a record picker. */
        @AuraEnabled
        public Integer referenceCount { get; set; }

        public Integer compareTo(Object other) {
            FieldOption peer = (FieldOption) other;
            String left = label == null ? '' : label.toLowerCase();
            String right = peer == null || peer.label == null ? '' : peer.label.toLowerCase();
            return left.compareTo(right);
        }
    }

    public class ToolTypeOption implements Comparable {
        @AuraEnabled
        public String value { get; set; }
        @AuraEnabled
        public String label { get; set; }
        /** Standard, Flow, or Apex. Whether the type builds its inputs comes from describeDraft, which may run the type's code. */
        @AuraEnabled
        public String implementationType { get; set; }

        public Integer compareTo(Object other) {
            ToolTypeOption peer = (ToolTypeOption) other;
            String left = label == null ? '' : label.toLowerCase();
            String right = peer == null || peer.label == null ? '' : peer.label.toLowerCase();
            return left.compareTo(right);
        }
    }

    /** One setting the tool type declares, with the control its type names. */
    public class SettingView {
        @AuraEnabled
        public String name { get; set; }
        @AuraEnabled
        public String label { get; set; }
        @AuraEnabled
        public String type { get; set; }
        @AuraEnabled
        public Boolean required { get; set; }
        @AuraEnabled
        public String helpText { get; set; }
        @AuraEnabled
        public List<String> allowedValues { get; set; }
        @AuraEnabled
        public String objectSetting { get; set; }
        /** For fields on one fixed object. */
        @AuraEnabled
        public String objectApiName { get; set; }
        /** For record: each object the record may belong to, with its label and ID prefix in meta. */
        @AuraEnabled
        public List<Option> recordObjects { get; set; }
        /** What the tool does when the setting is blank. */
        @AuraEnabled
        public String blankMeaning { get; set; }
    }

    /** One input the model sees, with what the tool builds next to the admin's edits. */
    public class InputRow {
        @AuraEnabled
        public String path { get; set; }
        @AuraEnabled
        public String name { get; set; }
        @AuraEnabled
        public Integer depth { get; set; }
        @AuraEnabled
        public String typeLabel { get; set; }
        @AuraEnabled
        public Boolean required { get; set; }
        /** Required by the tool itself, so an edit cannot clear it. */
        @AuraEnabled
        public Boolean requiredByTool { get; set; }
        @AuraEnabled
        public String description { get; set; }
        /** The description the tool builds, shown when the admin resets an edit. */
        @AuraEnabled
        public String toolDescription { get; set; }
        /** The values the model may send now; null when any value of the type is allowed. */
        @AuraEnabled
        public List<String> allowedValues { get; set; }
        /** The values the tool offers, which an edit may narrow. */
        @AuraEnabled
        public List<String> offeredValues { get; set; }
        @AuraEnabled
        public Boolean hasChildren { get; set; }
        @AuraEnabled
        public Boolean edited { get; set; }
        /** True when every value the input was limited to is gone, so the model does not see it. */
        @AuraEnabled
        public Boolean leftOut { get; set; }
        /** False for a hand-written schema, whose inputs the admin edits in the inputs builder. */
        @AuraEnabled
        public Boolean editable { get; set; }
        /** True for free text, whose values and length an edit may limit. */
        @AuraEnabled
        public Boolean isText { get; set; }
        /** The length limit the model sees now. */
        @AuraEnabled
        public Integer maxLength { get; set; }
        /** The length limit the tool builds, which an edit may lower. */
        @AuraEnabled
        public Integer toolMaxLength { get; set; }
    }

    /** A problem and where it belongs: toolType, settings, inputSchema, or an input path. */
    public class Problem {
        @AuraEnabled
        public String target { get; set; }
        @AuraEnabled
        public String message { get; set; }

        Problem(String target, String message) {
            this.target = target;
            this.message = message;
        }
    }

    public class DraftView {
        @AuraEnabled
        public String toolType { get; set; }
        @AuraEnabled
        public Boolean buildsInputs { get; set; }
        /** False when the tool type does not describe its settings, so they are typed as JSON. */
        @AuraEnabled
        public Boolean declaresSettings { get; set; }
        @AuraEnabled
        public List<SettingView> settings { get; set; }
        @AuraEnabled
        public List<InputRow> inputs { get; set; }
        /** The exact schema the model is sent, formatted for reading; null when there is a problem. */
        @AuraEnabled
        public String schemaJson { get; set; }
        @AuraEnabled
        public List<Problem> problems { get; set; }
    }

    public class ToolState {
        @AuraEnabled
        public String toolType { get; set; }
        @AuraEnabled
        public String implementationConfiguration { get; set; }
        @AuraEnabled
        public String inputSchema { get; set; }
        @AuraEnabled
        public DraftView view { get; set; }
    }

    // ===== TOOL =====

    /** Every registered tool type, so the editor offers one Tool Type list. */
    @AuraEnabled(cacheable=true)
    public static List<ToolTypeOption> getToolTypes() {
        List<ToolTypeOption> options = new List<ToolTypeOption>();
        for (AgentToolType__mdt toolType : AgentToolTypeService.toolTypes()) {
            ToolTypeOption option = new ToolTypeOption();
            option.value = toolType.DeveloperName;
            option.label = String.isBlank(toolType.MasterLabel) ? toolType.DeveloperName : toolType.MasterLabel;
            option.implementationType = AgentToolTypeService.implementationType(toolType);
            options.add(option);
        }
        options.sort();
        return options;
    }

    /** The saved tool and what its inputs are now. Not cacheable: the page reloads right after a save. */
    @AuraEnabled
    public static ToolState loadTool(Id toolId) {
        if (toolId == null) {
            throw handled('A tool record is required.');
        }
        AgentTool__c tool;
        try {
            tool = [
                SELECT DeveloperName__c, ToolType__c, ImplementationConfiguration__c, InputSchema__c
                FROM AgentTool__c
                WHERE Id = :toolId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException denied) {
            throw handled('The current user cannot read this tool.');
        }
        ToolState state = new ToolState();
        state.toolType = tool.ToolType__c;
        state.implementationConfiguration = tool.ImplementationConfiguration__c;
        state.inputSchema = tool.InputSchema__c;
        // A new record holds only what the editor knows, as a draft does, so Core's checks read no field this query left out.
        state.view = view(
            new AgentTool__c(
                Id = tool.Id,
                DeveloperName__c = tool.DeveloperName__c,
                ToolType__c = tool.ToolType__c,
                ImplementationConfiguration__c = tool.ImplementationConfiguration__c,
                InputSchema__c = tool.InputSchema__c
            )
        );
        return state;
    }

    /**
     * What a draft gives the model: the declared settings, each input with
     * the admin's edits, the exact schema, and every problem saving it active
     * would report, each placed where it belongs. Reads and writes no record.
     */
    @AuraEnabled
    public static DraftView describeDraft(String toolType, String implementationConfiguration, String inputSchema) {
        assertToolReadable();
        return view(
            new AgentTool__c(
                ToolType__c = blankToNull(toolType),
                ImplementationConfiguration__c = blankToNull(implementationConfiguration),
                InputSchema__c = blankToNull(inputSchema)
            )
        );
    }

    /** Saves the header and the draft in one write. A refused save writes nothing and says why. */
    @AuraEnabled
    public static Id saveTool(AgentTool__c header, String toolType, String implementationConfiguration, String inputSchema) {
        if (header == null) {
            throw handled('A complete tool draft is required.');
        }
        assertToolEditable();
        AgentTool__c tool = new AgentTool__c();
        Map<String, Object> supplied = header.getPopulatedFieldsAsMap();
        for (String fieldName : supplied.keySet()) {
            if (fieldName == 'Id') {
                tool.Id = (Id) supplied.get(fieldName);
            } else if (EDITABLE_TOOL_FIELDS.contains(fieldName)) {
                tool.put(fieldName, supplied.get(fieldName));
            } else {
                throw handled('The tool draft contains a field that cannot be edited here: ' + fieldName + '. Refresh the page and try again.');
            }
        }
        String type = blankToNull(toolType);
        if (type == null || AgentToolTypeService.toolType(type) == null) {
            throw handled(type == null ? 'Choose a Tool Type.' : AgentToolTypeService.unavailableMessage(type));
        }
        tool.ToolType__c = type;
        tool.ImplementationConfiguration__c = normalizedConfiguration(implementationConfiguration);
        tool.InputSchema__c = ToolAuthoringService.buildsInputs(tool) ? null : blankToNull(inputSchema);
        try {
            if (tool.Id == null) {
                Database.insert(tool, AccessLevel.USER_MODE);
            } else {
                Database.update(tool, AccessLevel.USER_MODE);
            }
            return tool.Id;
        } catch (DmlException failure) {
            // Core's save checks explain what to fix.
            throw saveFailed(failure);
        }
    }

    private static DraftView view(AgentTool__c tool) {
        DraftView result = new DraftView();
        result.toolType = tool.ToolType__c;
        result.settings = new List<SettingView>();
        result.inputs = new List<InputRow>();
        result.problems = new List<Problem>();
        if (tool.ToolType__c == null || AgentToolTypeService.toolType(tool) == null) {
            result.buildsInputs = false;
            result.problems.add(
                new Problem('toolType', tool.ToolType__c == null ? 'Choose a Tool Type.' : AgentToolTypeService.unavailableMessage(tool.ToolType__c))
            );
            return result;
        }
        ToolSchemaService.Resolution resolution = ToolSchemaService.effectiveSchema(tool);
        result.buildsInputs = resolution.built;
        result.declaresSettings = resolution.authoring != null;
        if (resolution.authoring != null && resolution.authoring.settings != null) {
            for (AgentKernelModels.ToolSetting setting : resolution.authoring.settings) {
                result.settings.add(settingView(setting));
            }
        }
        result.schemaJson = resolution.schema == null ? null : CanonicalJson.serializeInOrder(JSON.deserializeUntyped(resolution.schema), true);
        if (result.buildsInputs) {
            String built = resolution.authoring == null ? null : resolution.authoring.inputSchema;
            result.inputs = builtRows(built, resolution.schema, tool.ImplementationConfiguration__c);
            if (built != null) {
                for (ToolInputOverrides.Problem problem : ToolInputOverrides.problemsByInput(built, tool.ImplementationConfiguration__c)) {
                    result.problems.add(new Problem(problem.path == null ? 'settings' : problem.path, problem.message));
                }
            }
        } else if (resolution.schema != null) {
            result.inputs = handWrittenRows(resolution.schema);
        }
        for (AgentConfigurationValidator.Finding finding : AgentConfigurationValidator.toolProblems(tool)) {
            if (finding.code != 'TOOL_INPUT_EDIT_INVALID') {
                result.problems.add(new Problem(targetOf(finding), finding.message));
            }
        }
        return result;
    }

    private static List<InputRow> builtRows(String built, String effective, String configuration) {
        List<InputRow> rows = new List<InputRow>();
        if (built == null) {
            return rows;
        }
        Map<String, ToolSchemaRows.Row> now = new Map<String, ToolSchemaRows.Row>();
        for (ToolSchemaRows.Row row : ToolSchemaRows.read(effective)) {
            now.put(row.path, row);
        }
        Set<String> edited = new Set<String>();
        try {
            edited = ToolInputOverrides.read(configuration).keySet();
        } catch (AgentKernelException.ConfigurationException unreadable) {
            // Reported as a settings problem.
        }
        for (ToolSchemaRows.Row tool : ToolSchemaRows.read(built)) {
            ToolSchemaRows.Row current = now.get(tool.path);
            InputRow row = new InputRow();
            row.path = tool.path;
            row.name = tool.name;
            row.depth = tool.depth;
            row.typeLabel = tool.typeLabel;
            row.requiredByTool = tool.required;
            row.required = current == null ? tool.required : current.required;
            row.toolDescription = tool.description;
            row.description = current == null ? tool.description : current.description;
            row.offeredValues = tool.allowedValues;
            row.allowedValues = current == null ? tool.allowedValues : current.allowedValues;
            row.hasChildren = tool.hasChildren;
            row.edited = edited.contains(tool.path);
            row.leftOut = effective != null && current == null;
            row.editable = true;
            row.isText = tool.valueType == 'string' && tool.allowedValues == null && tool.format == null;
            row.toolMaxLength = tool.maxLength;
            row.maxLength = current == null ? tool.maxLength : current.maxLength;
            rows.add(row);
        }
        return rows;
    }

    private static List<InputRow> handWrittenRows(String schema) {
        List<InputRow> rows = new List<InputRow>();
        for (ToolSchemaRows.Row source : ToolSchemaRows.read(schema)) {
            InputRow row = new InputRow();
            row.path = source.path;
            row.name = source.name;
            row.depth = source.depth;
            row.typeLabel = source.typeLabel;
            row.required = source.required;
            row.requiredByTool = source.required;
            row.description = source.description;
            row.toolDescription = source.description;
            row.allowedValues = source.allowedValues;
            row.offeredValues = source.allowedValues;
            row.hasChildren = source.hasChildren;
            row.edited = false;
            row.leftOut = false;
            row.editable = false;
            rows.add(row);
        }
        return rows;
    }

    private static String targetOf(AgentConfigurationValidator.Finding finding) {
        String path = finding.path == null ? '' : finding.path;
        if (path.endsWith('.InputSchema')) {
            return 'inputSchema';
        }
        if (path.endsWith('.ToolType')) {
            return 'toolType';
        }
        return 'settings';
    }

    private static SettingView settingView(AgentKernelModels.ToolSetting setting) {
        SettingView view = new SettingView();
        view.name = setting.name;
        view.label = String.isBlank(setting.label) ? setting.name : setting.label;
        view.type = String.isBlank(setting.type) ? 'json' : setting.type;
        view.required = setting.required == true;
        view.helpText = setting.helpText;
        view.allowedValues = setting.allowedValues;
        view.objectSetting = setting.objectSetting;
        view.objectApiName = setting.objectApiName;
        view.blankMeaning = setting.blankMeaning;
        if (setting.recordObjects != null) {
            view.recordObjects = new List<Option>();
            for (String objectApiName : setting.recordObjects) {
                Schema.SObjectType objectType = objectType(objectApiName);
                if (objectType == null) {
                    continue;
                }
                Schema.DescribeSObjectResult describe = objectType.getDescribe();
                Option option = new Option();
                option.value = describe.getName();
                option.label = describe.getLabel();
                option.meta = describe.getKeyPrefix();
                view.recordObjects.add(option);
            }
        }
        return view;
    }

    private static String normalizedConfiguration(String configuration) {
        String value = blankToNull(configuration);
        if (value == null) {
            return null;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(value);
        } catch (Exception invalidJson) {
            throw handled('Settings must be a JSON object.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw handled('Settings must be a JSON object.');
        }
        return ((Map<String, Object>) parsed).isEmpty() ? null : value;
    }

    // ===== PICKERS =====

    /** Objects an admin may pick anywhere in Pluto. */
    @AuraEnabled(cacheable=true)
    public static List<Option> searchSObjects(String term) {
        List<Option> matches = new List<Option>();
        if (String.isBlank(term) || term.trim().length() < 2) {
            return matches;
        }
        String needle = term.trim().toLowerCase();
        for (Schema.SObjectType objectType : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = objectType.getDescribe(SObjectDescribeOptions.DEFERRED);
            if (isPickableObject(describe) && matchesTerm(describe, needle)) {
                matches.add(objectOption(describe));
            }
        }
        return withObjectIcons(matches, needle);
    }

    /**
     * Objects a tool type may name: any readable business object for Query
     * Records, and a createable or updateable one for Create or Update
     * Record. Pluto Core objects are never offered.
     */
    @AuraEnabled(cacheable=true)
    public static List<Option> searchStandardTargetSObjects(String term, String operation) {
        List<Option> matches = new List<Option>();
        if (String.isBlank(term) || term.trim().length() < 2) {
            return matches;
        }
        Boolean isCreate = 'CreateRecord'.equalsIgnoreCase(operation);
        Boolean isUpdate = 'UpdateRecord'.equalsIgnoreCase(operation);
        String needle = term.trim().toLowerCase();
        for (Schema.SObjectType objectType : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult describe = objectType.getDescribe(SObjectDescribeOptions.DEFERRED);
            if (
                !isPickableObject(describe) ||
                StandardToolSupport.isCoreObject(describe.getName()) ||
                (isCreate && !describe.isCreateable()) ||
                (isUpdate && !describe.isUpdateable()) ||
                !matchesTerm(describe, needle)
            ) {
                continue;
            }
            matches.add(objectOption(describe));
        }
        return withObjectIcons(matches, needle);
    }

    @AuraEnabled(cacheable=true)
    public static List<FieldOption> getFieldOptions(String objectApiName) {
        List<FieldOption> fields = new List<FieldOption>();
        Schema.SObjectType objectType = objectType(objectApiName);
        if (objectType == null || !objectType.getDescribe().isAccessible()) {
            return fields;
        }
        for (Schema.SObjectField field : objectType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (!describe.isAccessible()) {
                continue;
            }
            FieldOption found = new FieldOption();
            found.value = describe.getName();
            found.label = describe.getLabel();
            found.subtitle = describe.getType().name() + ' • ' + describe.getName();
            found.description = describe.getInlineHelpText() == null ? '' : describe.getInlineHelpText();
            found.dataType = describe.getType().name();
            found.fieldType = describe.getType().name();
            found.required = !describe.isNillable() && !describe.isDefaultedOnCreate() && describe.getType() != Schema.DisplayType.BOOLEAN;
            found.createable = describe.isCreateable();
            found.updateable = describe.isUpdateable();
            found.isPicklist =
                describe.getType() == Schema.DisplayType.PICKLIST ||
                describe.getType() == Schema.DisplayType.MULTIPICKLIST ||
                describe.getType() == Schema.DisplayType.COMBOBOX;
            found.picklistValues = new List<PicklistOption>();
            if (found.isPicklist) {
                for (Schema.PicklistEntry entry : describe.getPicklistValues()) {
                    if (!entry.isActive()) {
                        continue;
                    }
                    PicklistOption choice = new PicklistOption();
                    choice.label = entry.getLabel();
                    choice.value = entry.getValue();
                    found.picklistValues.add(choice);
                }
            }
            found.pointsToUser = describe.getReferenceTo() != null && describe.getReferenceTo().contains(User.SObjectType);
            found.referenceCount = describe.getReferenceTo() == null ? 0 : describe.getReferenceTo().size();
            if (describe.getReferenceTo() != null && !describe.getReferenceTo().isEmpty()) {
                found.referenceTo = String.valueOf(describe.getReferenceTo()[0]);
                if (describe.getReferenceTo().size() == 1 && !StandardToolSupport.isCoreObject(found.referenceTo)) {
                    found.relationshipName = describe.getRelationshipName();
                }
            }
            fields.add(found);
        }
        fields.sort();
        return fields;
    }

    /**
     * The fields a new Create or Update Record tool starts with: the ones a
     * record cannot be saved without, which the tool can write. Fields the
     * platform fills and checkboxes are left out. At most 30.
     */
    @AuraEnabled(cacheable=true)
    public static List<String> getStartingFields(String objectApiName, String toolType) {
        List<String> result = new List<String>();
        Schema.SObjectType objectType = objectType(objectApiName);
        if (objectType == null) {
            return result;
        }
        Boolean creating = 'CreateRecord'.equalsIgnoreCase(toolType);
        for (Schema.SObjectField field : objectType.getDescribe().fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            Boolean writable = creating ? describe.isCreateable() : describe.isUpdateable();
            if (
                result.size() < MAX_WRITABLE_FIELDS &&
                writable &&
                describe.isAccessible() &&
                !describe.isNillable() &&
                !describe.isDefaultedOnCreate() &&
                describe.getType() != Schema.DisplayType.BOOLEAN
            ) {
                result.add(describe.getName());
            }
        }
        result.sort();
        return result;
    }

    /**
     * The child relationships a query on this object may read in a child
     * subquery, such as Contacts on Account: value is the relationship name,
     * label the child object. Children the user cannot read and Pluto Core
     * objects are left out.
     */
    @AuraEnabled(cacheable=true)
    public static List<Option> getChildRelationshipOptions(String objectApiName) {
        List<Option> options = new List<Option>();
        Schema.SObjectType objectType = objectType(objectApiName);
        if (objectType == null || !objectType.getDescribe().isAccessible()) {
            return options;
        }
        for (Schema.ChildRelationship child : objectType.getDescribe().getChildRelationships()) {
            if (String.isBlank(child.getRelationshipName())) {
                continue;
            }
            Schema.DescribeSObjectResult childDescribe = child.getChildSObject().getDescribe(SObjectDescribeOptions.DEFERRED);
            if (!childDescribe.isAccessible() || !childDescribe.isQueryable() || StandardToolSupport.isCoreObject(childDescribe.getName())) {
                continue;
            }
            Option option = new Option();
            option.value = child.getRelationshipName();
            option.label = childDescribe.getName();
            options.add(option);
        }
        return options;
    }

    /** The active record types besides Master, by developer name. */
    @AuraEnabled(cacheable=true)
    public static List<Option> getRecordTypeOptions(String objectApiName) {
        List<Option> options = new List<Option>();
        Schema.SObjectType objectType = objectType(objectApiName);
        if (objectType == null) {
            return options;
        }
        for (Schema.RecordTypeInfo info : objectType.getDescribe().getRecordTypeInfos()) {
            if (!info.isMaster() && info.isActive()) {
                Option option = new Option();
                option.value = info.getDeveloperName();
                option.label = info.getName();
                options.add(option);
            }
        }
        options.sort();
        return options;
    }

    /**
     * Active autolaunched Flows in the org's own namespace whose label or API
     * name has the term, up to 200, so a picker can list them all. The term is
     * matched here: FlowDefinitionView fails on LIKE filters.
     */
    @AuraEnabled(cacheable=true)
    public static List<Option> searchFlows(String term) {
        List<Option> matches = new List<Option>();
        String needle = String.isBlank(term) ? null : term.trim().toLowerCase();
        try {
            for (FlowDefinitionView definition : [
                SELECT ApiName, Label
                FROM FlowDefinitionView
                WHERE ProcessType = 'AutoLaunchedFlow' AND IsActive = TRUE AND NamespacePrefix = NULL
                WITH SYSTEM_MODE
                ORDER BY Label
                LIMIT 2000
            ]) {
                if (needle != null && !definition.ApiName.toLowerCase().contains(needle) && !definition.Label.toLowerCase().contains(needle)) {
                    continue;
                }
                Option found = new Option();
                found.value = definition.ApiName;
                found.label = definition.Label + ' • ' + definition.ApiName;
                matches.add(found);
                if (matches.size() == 200) {
                    break;
                }
            }
        } catch (Exception unavailable) {
            return new List<Option>();
        }
        return matches;
    }

    /** Queues by API name, for a queue setting. */
    @AuraEnabled(cacheable=true)
    public static List<Option> getQueueOptions() {
        List<Option> options = new List<Option>();
        for (Group queue : [SELECT DeveloperName, Name FROM Group WHERE Type = 'Queue' WITH USER_MODE ORDER BY Name LIMIT 1000]) {
            Option option = new Option();
            option.value = queue.DeveloperName;
            option.label = queue.Name + ' • ' + queue.DeveloperName;
            options.add(option);
        }
        return options;
    }

    /** Named Credentials by API name, for a namedCredential setting. */
    @AuraEnabled(cacheable=true)
    public static List<Option> getNamedCredentialOptions() {
        List<Option> options = new List<Option>();
        try {
            for (NamedCredential credential : [SELECT DeveloperName, MasterLabel FROM NamedCredential WITH SYSTEM_MODE ORDER BY MasterLabel LIMIT 1000]) {
                Option option = new Option();
                option.value = credential.DeveloperName;
                option.label = credential.MasterLabel + ' • ' + credential.DeveloperName;
                options.add(option);
            }
        } catch (Exception unavailable) {
            return new List<Option>();
        }
        return options;
    }

    /** Reports the user can see whose name or API name has the term, for a report setting. */
    @AuraEnabled(cacheable=true)
    public static List<Option> searchReports(String term) {
        List<Option> matches = new List<Option>();
        if (String.isBlank(term) || term.trim().length() < 2) {
            return matches;
        }
        String likeTerm = '%' + term.trim() + '%';
        try {
            for (Report found : [
                SELECT DeveloperName, Name, FolderName
                FROM Report
                WHERE Name LIKE :likeTerm OR DeveloperName LIKE :likeTerm
                WITH USER_MODE
                ORDER BY Name
                LIMIT :MAX_SEARCH_RESULTS
            ]) {
                Option option = new Option();
                option.value = found.DeveloperName;
                option.label = found.Name;
                option.meta = found.FolderName;
                option.iconName = 'standard:report';
                matches.add(option);
            }
        } catch (Exception unavailable) {
            return new List<Option>();
        }
        return matches;
    }

    // ===== HELPERS =====

    private static Schema.SObjectType objectType(String objectApiName) {
        return String.isBlank(objectApiName) ? null : Schema.getGlobalDescribe().get(objectApiName.trim());
    }

    /**
     * Objects an admin picks in Pluto: business record objects the user can
     * read. Apex describe has no page-layout flag, so standard objects must
     * be searchable, which leaves out setup and system objects; custom
     * objects count even with search turned off. Companion objects, custom
     * settings, custom metadata types, big objects, and hidden deprecated
     * objects are left out.
     */
    private static Boolean isPickableObject(Schema.DescribeSObjectResult describe) {
        String objectApiName = describe.getName();
        return describe.isQueryable() &&
            describe.isAccessible() &&
            (describe.isSearchable() || describe.isCustom()) &&
            !describe.isCustomSetting() &&
            !describe.isDeprecatedAndHidden() &&
            describe.getAssociateEntityType() == null &&
            !objectApiName.endsWithIgnoreCase('__mdt') &&
            !objectApiName.endsWithIgnoreCase('__b');
    }

    private static Boolean matchesTerm(Schema.DescribeSObjectResult describe, String needle) {
        String objectLabel = describe.getLabel();
        return describe.getName().toLowerCase().contains(needle) || (objectLabel != null && objectLabel.toLowerCase().contains(needle));
    }

    private static Option objectOption(Schema.DescribeSObjectResult describe) {
        String apiName = describe.getName();
        String objectLabel = describe.getLabel();
        Option found = new Option();
        found.value = apiName;
        found.label = (String.isBlank(objectLabel) ? apiName : objectLabel) + ' • ' + apiName;
        found.iconName = describe.isCustom() ? 'custom:custom11' : 'standard:default';
        return found;
    }

    /**
     * Ranks object matches (exact API name or label, then prefix, then any
     * other match, each alphabetical), caps them, then uses each object's
     * Lightning tab icon when it has one.
     */
    private static List<Option> withObjectIcons(List<Option> matches, String needle) {
        matches.sort();
        List<Option> exact = new List<Option>();
        List<Option> prefix = new List<Option>();
        List<Option> other = new List<Option>();
        for (Option found : matches) {
            String apiName = found.value.toLowerCase();
            String objectLabel = found.label.substringBefore(' • ').toLowerCase();
            if (apiName == needle || objectLabel == needle) {
                exact.add(found);
            } else if (apiName.startsWith(needle) || objectLabel.startsWith(needle)) {
                prefix.add(found);
            } else {
                other.add(found);
            }
        }
        exact.addAll(prefix);
        exact.addAll(other);
        Map<String, Option> capped = new Map<String, Option>();
        for (Integer i = 0; i < exact.size() && i < MAX_SEARCH_RESULTS; i++) {
            capped.put(exact[i].value, exact[i]);
        }
        if (capped.isEmpty()) {
            return capped.values();
        }
        for (TabDefinition tab : [
            SELECT SobjectName, (SELECT Url FROM Icons WHERE Theme = 'theme4')
            FROM TabDefinition
            WHERE SobjectName IN :capped.keySet()
            WITH SYSTEM_MODE
        ]) {
            for (IconDefinition icon : tab.Icons) {
                String iconName = sldsIconName(icon.Url);
                if (iconName != null) {
                    capped.get(tab.SobjectName).iconName = iconName;
                    break;
                }
            }
        }
        return capped.values();
    }

    /** Maps a tab icon URL such as .../standard/account_120.png to an SLDS icon name. */
    @TestVisible
    private static String sldsIconName(String url) {
        if (String.isBlank(url)) {
            return null;
        }
        Matcher parts = SLDS_ICON_PATH.matcher(url.toLowerCase());
        return parts.matches() ? parts.group(1) + ':' + parts.group(2) : null;
    }

    private static void assertToolReadable() {
        if (!Schema.sObjectType.AgentTool__c.isAccessible()) {
            throw handled('The current user cannot read tools. Assign the Agent Tool Authoring permission set.');
        }
    }

    private static void assertToolEditable() {
        if (
            !Schema.sObjectType.AgentTool__c.isUpdateable() ||
            !Schema.sObjectType.AgentTool__c.fields.InputSchema__c.isUpdateable() ||
            !Schema.sObjectType.AgentTool__c.fields.ImplementationConfiguration__c.isUpdateable() ||
            !Schema.sObjectType.AgentTool__c.fields.ToolType__c.isUpdateable()
        ) {
            throw handled('The current user cannot edit this tool. Assign the Agent Tool Authoring permission set.');
        }
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static AuraHandledException saveFailed(DmlException failure) {
        String detail = failure.getDmlMessage(0);
        if (String.isBlank(detail)) {
            detail = failure.getMessage();
        }
        return handled(detail == null ? null : detail.abbreviate(1000));
    }

    /** An exception whose message reaches the admin and tests, not "Script-thrown exception". */
    private static AuraHandledException handled(String message) {
        AuraHandledException surfaced = new AuraHandledException(message);
        surfaced.setMessage(message);
        return surfaced;
    }
}
