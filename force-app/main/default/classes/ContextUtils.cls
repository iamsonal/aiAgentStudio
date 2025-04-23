/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Utility class for shared, cached access to Schema information (SObjectTypes, Fields)
 *              and related checks needed by context processing (Trigger, Service, Builder).
 *              Uses static, transaction-scoped caches.
 */
public inherited sharing class ContextUtils {
    private static Map<String, SObjectType> sObjectTypeCache = new Map<String, SObjectType>();

    private static Map<String, Map<String, SObjectField>> fieldDescribeCache = new Map<String, Map<String, SObjectField>>();

    public static final Set<String> ALLOWED_FILTER_OPERATORS = new Set<String>{
        '=',
        '!=',
        '<',
        '>',
        '<=',
        '>=',
        'IN',
        'NOT IN',
        'LIKE'
    };

    /**
     * @description Clears static caches. Call at the beginning of trigger handlers or specific service methods if needed.
     */
    public static void clearCaches() {
        sObjectTypeCache.clear();
        fieldDescribeCache.clear();
    }

    /**
     * @description Gets an SObjectType from cache or Schema.
     * @param apiName API Name of the SObject (case-insensitive).
     * @return SObjectType or null if not found or inaccessible.
     */
    public static SObjectType getSObjectType(String apiName) {
        if (String.isBlank(apiName))
            return null;

        String lowerApiName = apiName.toLowerCase();
        if (!sObjectTypeCache.containsKey(lowerApiName)) {
            SObjectType objType = null;
            try {
                objType = Schema.getGlobalDescribe().get(lowerApiName);
                if (objType == null) {
                }
            } catch (Exception e) {
            }
            sObjectTypeCache.put(lowerApiName, objType);
        }
        return sObjectTypeCache.get(lowerApiName);
    }

    /**
     * @description Gets the map of fields for an SObject from cache or Schema.
     * @param sObjectType The SObjectType.
     * @return Map<String, SObjectField> (lowercase field API name key) or an empty map if describe fails.
     */
    public static Map<String, SObjectField> getObjectFields(SObjectType sObjectType) {
        if (sObjectType == null)
            return new Map<String, SObjectField>();
        String typeName = sObjectType.getDescribe().getName().toLowerCase();
        if (!fieldDescribeCache.containsKey(typeName)) {
            Map<String, SObjectField> fieldMap = new Map<String, SObjectField>();
            try {
                Map<String, SObjectField> originalCaseMap = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
                    .fields.getMap();

                for (String fieldKey : originalCaseMap.keySet()) {
                    fieldMap.put(fieldKey.toLowerCase(), originalCaseMap.get(fieldKey));
                }
            } catch (Exception e) {
            }
            fieldDescribeCache.put(typeName, fieldMap);
        }
        return fieldDescribeCache.get(typeName);
    }

    /**
     * @description Gets a specific SObjectField token.
     * @param sObjectType The SObjectType.
     * @param fieldName API name of the field (case-insensitive).
     * @return SObjectField token or null if not found.
     */
    public static SObjectField getFieldToken(SObjectType sObjectType, String fieldName) {
        if (sObjectType == null || String.isBlank(fieldName))
            return null;
        Map<String, SObjectField> objFields = getObjectFields(sObjectType);
        return objFields?.get(fieldName.toLowerCase());
    }

    /**
     * @description Checks if a specific field exists and is accessible (readable) for the current user.
     * @param sObjectType The SObjectType.
     * @param fieldName API name of the field (case-insensitive).
     * @return True if the field exists and is accessible, false otherwise.
     */
    public static Boolean isFieldAccessible(SObjectType sObjectType, String fieldName) {
        SObjectField fieldToken = getFieldToken(sObjectType, fieldName);
        try {
            return fieldToken != null && fieldToken.getDescribe().isAccessible();
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Checks if a specific field exists and is filterable.
     * @param sObjectType The SObjectType.
     * @param fieldName API name of the field (case-insensitive).
     * @return True if the field exists and is filterable, false otherwise.
     */
    public static Boolean isFieldFilterable(SObjectType sObjectType, String fieldName) {
        SObjectField fieldToken = getFieldToken(sObjectType, fieldName);
        try {
            return fieldToken != null && fieldToken.getDescribe().isFilterable();
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Checks if a specific field exists and is sortable.
     * @param sObjectType The SObjectType.
     * @param fieldName API name of the field (case-insensitive).
     * @return True if the field exists and is sortable, false otherwise.
     */
    public static Boolean isFieldSortable(SObjectType sObjectType, String fieldName) {
        SObjectField fieldToken = getFieldToken(sObjectType, fieldName);
        try {
            return fieldToken != null && fieldToken.getDescribe().isSortable();
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * @description Validates a relationship field path (1 level deep, e.g., Account.Name).
     *              Checks existence and specified property (accessible, sortable, filterable) on the related field.
     * @param baseObjType The SObject type where the query starts (e.g., OpportunityLineItem)
     * @param relationshipFieldName API Name of the lookup field OR Relationship Name (e.g., Product2Id or Product2)
     * @param fieldOnRelated API name of the field on the related object (e.g., Name)
     * @param checkType Property to check: 'accessible', 'sortable', 'filterable'
     * @return Map containing 'isValid' (Boolean) and 'errorMessage' (String if invalid)
     */
    public static Map<String, Object> validateRelationshipField(
        SObjectType baseObjType,
        String relationshipFieldName,
        String fieldOnRelated,
        String checkType
    ) {
        Map<String, Object> validationResult = new Map<String, Object>{ 'isValid' => false, 'errorMessage' => '' };

        if (baseObjType == null || String.isBlank(relationshipFieldName) || String.isBlank(fieldOnRelated)) {
            validationResult.put('errorMessage', 'Missing base type, relationship field, or related field.');
            return validationResult;
        }

        RelationshipInfo relInfo = getRelatedSObjectType(baseObjType, relationshipFieldName);

        if (relInfo.relatedType == null) {
            validationResult.put('errorMessage', relInfo.errorMessage);
            return validationResult;
        }

        Boolean isPropValid = false;
        String propertyName = checkType;
        switch on checkType.toLowerCase() {
            when 'accessible' {
                isPropValid = isFieldAccessible(relInfo.relatedType, fieldOnRelated);
            }
            when 'sortable' {
                isPropValid = isFieldSortable(relInfo.relatedType, fieldOnRelated);
            }
            when 'filterable' {
                isPropValid = isFieldFilterable(relInfo.relatedType, fieldOnRelated);
            }
            when else {
                propertyName = 'exists';
                isPropValid = (getFieldToken(relInfo.relatedType, fieldOnRelated) != null);
            }
        }

        if (isPropValid) {
            validationResult.put('isValid', true);
        } else {
            String fieldNotFoundMsg = (getFieldToken(relInfo.relatedType, fieldOnRelated) == null)
                ? ' (Field does not exist)'
                : '';
            validationResult.put(
                'errorMessage',
                'Field "' +
                    fieldOnRelated +
                    '" on related object ' +
                    relInfo.relatedType.getDescribe().getName() +
                    ' (via ' +
                    relInfo.relationshipName +
                    ') is not ' +
                    propertyName +
                    '.' +
                    fieldNotFoundMsg
            );
        }

        return validationResult;
    }

    /**
     * @description Helper class to store relationship information
     */
    private class RelationshipInfo {
        public SObjectType relatedType;
        public String relationshipName;
        public String errorMessage;
    }

    /**
     * @description Extract logic for getting related SObjectType from relationship field
     * @param baseObjType Base SObject type
     * @param relationshipFieldName API name or relationship name
     * @return RelationshipInfo with related SObjectType and relationship details
     */
    private static RelationshipInfo getRelatedSObjectType(SObjectType baseObjType, String relationshipFieldName) {
        RelationshipInfo info = new RelationshipInfo();
        Map<String, SObjectField> baseObjectFields = getObjectFields(baseObjType);

        SObjectField baseFieldToken = baseObjectFields.get(relationshipFieldName.toLowerCase());
        if (baseFieldToken != null && baseFieldToken.getDescribe().getType() == DisplayType.REFERENCE) {
            info.relationshipName = relationshipFieldName;
            try {
                List<Schema.SObjectType> refTos = baseFieldToken.getDescribe().getReferenceTo();
                if (refTos != null && !refTos.isEmpty()) {
                    info.relatedType = refTos[0];
                    return info;
                }
            } catch (Exception describeEx) {
                info.errorMessage =
                    'Error describing reference field "' +
                    relationshipFieldName +
                    '": ' +
                    describeEx.getMessage();
                return info;
            }
        }

        for (SObjectField potentialRefField : baseObjectFields.values()) {
            DescribeFieldResult dfr;
            try {
                dfr = potentialRefField.getDescribe();
                if (
                    dfr.getType() == DisplayType.REFERENCE &&
                    relationshipFieldName.equalsIgnoreCase(dfr.getRelationshipName())
                ) {
                    info.relationshipName = dfr.getRelationshipName();
                    List<Schema.SObjectType> refTos = dfr.getReferenceTo();
                    if (refTos != null && !refTos.isEmpty()) {
                        info.relatedType = refTos[0];
                        return info;
                    }
                }
            } catch (Exception e) {
            }
        }

        info.errorMessage =
            'Could not find relationship "' +
            relationshipFieldName +
            '" on ' +
            baseObjType.getDescribe().getName() +
            '.';
        return info;
    }

    /**
     * @description Parses and validates the FilterBy JSON string against a target SObject.
     * @param filterJson The FilterBy__c JSON string.
     * @param targetSObjectType The SObjectType the filter applies to.
     * @return ContextParseResult Indicating validity, errors, and parsed conditions.
     */
    public static ContextParseResult parseAndValidateFilterBy(String filterJson, SObjectType targetSObjectType) {
        ContextParseResult result = new ContextParseResult();

        if (targetSObjectType == null) {
            result.addError('Target SObject type is null.');
            return result;
        }
        if (String.isBlank(filterJson)) {
            return result;
        }

        Object parsedJson;
        try {
            parsedJson = JSON.deserializeUntyped(filterJson);
        } catch (Exception e) {
            result.addError('Invalid JSON Syntax: ' + e.getMessage());
            return result;
        }

        List<Object> conditionsListUntyped = extractConditionsList(parsedJson, result);
        if (!result.isValid || conditionsListUntyped == null) {
            return result;
        }

        if (conditionsListUntyped.isEmpty()) {
            return result;
        }

        validateConditions(conditionsListUntyped, targetSObjectType, result);

        return result;
    }

    /**
     * @description Extracts conditions list from parsed JSON
     * @param parsedJson The parsed JSON object
     * @param result The result object to track errors
     * @return List of condition objects or null if invalid
     */
    private static List<Object> extractConditionsList(Object parsedJson, ContextParseResult result) {
        if (parsedJson instanceof List<Object>) {
            return (List<Object>) parsedJson;
        } else if (parsedJson instanceof Map<String, Object>) {
            Map<String, Object> complexMap = (Map<String, Object>) parsedJson;

            Object logicObj = complexMap.get('conditionLogic');
            if (logicObj instanceof String && String.isNotBlank((String) logicObj)) {
                String logicStr = ((String) logicObj).toUpperCase();
                if (logicStr == 'OR') {
                    result.conditionLogic = 'OR';
                } else if (logicStr != 'AND') {
                    result.addError('Unsupported conditionLogic: ' + logicObj + '. Use AND or OR.');
                }
            }

            if (!complexMap.containsKey('conditions') || !(complexMap.get('conditions') instanceof List<Object>)) {
                result.addError('Complex filter map must contain key "conditions" with a List value.');
                return null;
            }
            return (List<Object>) complexMap.get('conditions');
        } else {
            result.addError('FilterBy JSON must be a List or a Map.');
            return null;
        }
    }

    /**
     * @description Validates individual condition objects
     * @param conditionsList List of condition objects to validate
     * @param targetSObjectType The SObject type to validate against
     * @param result The result object to track errors and validated conditions
     */
    private static void validateConditions(
        List<Object> conditionsList,
        SObjectType targetSObjectType,
        ContextParseResult result
    ) {
        Integer index = 0;
        for (Object conditionItem : conditionsList) {
            index++;

            if (!(conditionItem instanceof Map<String, Object>)) {
                result.addError('Filter condition ' + index + ' is not a valid JSON Object map.');
                continue;
            }

            Map<String, Object> condMap = (Map<String, Object>) conditionItem;
            ValidatedCondition vCond = new ValidatedCondition();
            Boolean currentConditionValid = validateConditionStructure(condMap, vCond, index, result);

            if (currentConditionValid && String.isNotBlank(vCond.fieldName)) {
                if (!ContextUtils.isFieldFilterable(targetSObjectType, vCond.fieldName)) {
                    result.addError(
                        'Filter condition ' +
                            index +
                            ': Field "' +
                            vCond.fieldName +
                            '" invalid, not filterable, or inaccessible on ' +
                            targetSObjectType.getDescribe().getName() +
                            '.'
                    );
                    currentConditionValid = false;
                }
            }

            if (String.isNotBlank(vCond.fieldName) && String.isNotBlank(vCond.operator)) {
                result.validatedConditions.add(vCond);
            }
        }
    }

    /**
     * @description Validates condition structure (field, operator, value)
     * @param condMap The condition map to validate
     * @param vCond The validated condition to populate
     * @param index Condition index (for error messages)
     * @param result Result object to add errors to
     * @return true if structure is valid
     */
    private static Boolean validateConditionStructure(
        Map<String, Object> condMap,
        ValidatedCondition vCond,
        Integer index,
        ContextParseResult result
    ) {
        Boolean isValid = true;

        Object fieldObj = condMap.get('field');
        if (!(fieldObj instanceof String) || String.isBlank((String) fieldObj)) {
            result.addError('Filter condition ' + index + ' missing/invalid "field" (must be non-blank String).');
            isValid = false;
        } else {
            vCond.fieldName = (String) fieldObj;
        }

        Object operatorObj = condMap.get('operator');
        if (!(operatorObj instanceof String) || String.isBlank((String) operatorObj)) {
            result.addError('Filter condition ' + index + ' missing/invalid "operator" (must be non-blank String).');
            isValid = false;
        } else {
            vCond.operator = ((String) operatorObj).toUpperCase();
            if (!ALLOWED_FILTER_OPERATORS.contains(vCond.operator)) {
                result.addError('Filter condition ' + index + ': Unsupported Operator "' + operatorObj + '".');
                isValid = false;
            }
        }

        vCond.value = condMap.get('value');
        if (
            ('IN'.equals(vCond.operator) || 'NOT IN'.equals(vCond.operator)) && !(vCond.value instanceof List<Object>)
        ) {
            result.addError(
                'Filter condition ' +
                    index +
                    ': Operator "' +
                    vCond.operator +
                    '" requires "value" to be a JSON Array (List).'
            );
            isValid = false;
        }

        return isValid;
    }

    /**
     * @description Parses and validates the OrderBy JSON string against a target SObject.
     * @param orderJson The OrderBy__c JSON string (expects a list of objects).
     * @param targetSObjectType The SObjectType the ordering applies to.
     * @return ContextParseResult Indicating validity, errors, and parsed order definitions.
     */
    public static ContextParseResult parseAndValidateOrderBy(String orderJson, SObjectType targetSObjectType) {
        ContextParseResult result = new ContextParseResult();
        if (targetSObjectType == null) {
            result.addError('Target SObject type is null.');
            return result;
        }
        if (String.isBlank(orderJson)) {
            return result;
        }

        List<Object> orderListUntyped;
        try {
            Object parsed = JSON.deserializeUntyped(orderJson);
            if (!(parsed instanceof List<Object>)) {
                throw new AuraHandledException('OrderBy JSON must be an Array.');
            }
            orderListUntyped = (List<Object>) parsed;
        } catch (Exception e) {
            result.addError('Invalid OrderBy JSON Syntax/Type: ' + e.getMessage());
            return result;
        }

        if (orderListUntyped.isEmpty()) {
            return result;
        }

        Integer index = 0;
        for (Object orderItem : orderListUntyped) {
            index++;
            if (!(orderItem instanceof Map<String, Object>)) {
                result.addError('OrderBy item ' + index + ' is not a valid JSON Object map.');
                continue;
            }
            Map<String, Object> orderMap = (Map<String, Object>) orderItem;
            ValidatedOrder vOrder = new ValidatedOrder();
            Boolean currentOrderValid = true;

            Object fieldObj = orderMap.get('field');
            if (!(fieldObj instanceof String) || String.isBlank((String) fieldObj)) {
                result.addError('OrderBy item ' + index + ' missing required "field" (non-blank String).');
                currentOrderValid = false;
            } else {
                vOrder.fieldPath = ((String) fieldObj).trim();
            }

            Object dirObj = orderMap.get('direction');
            if (dirObj == null || (dirObj instanceof String && String.isBlank((String) dirObj))) {
                vOrder.direction = 'ASC';
            } else if (dirObj instanceof String) {
                String dirStr = ((String) dirObj).toUpperCase();
                if ('DESC'.equals(dirStr)) {
                    vOrder.direction = 'DESC';
                } else if ('ASC'.equals(dirStr)) {
                    vOrder.direction = 'ASC';
                } else {
                    result.addError('OrderBy item ' + index + ' invalid "direction": ' + dirObj);
                    currentOrderValid = false;
                }
            } else {
                result.addError('OrderBy item ' + index + ' invalid type for "direction": ' + dirObj);
                currentOrderValid = false;
            }

            Object nullsObj = orderMap.get('nulls');
            if (nullsObj == null || (nullsObj instanceof String && String.isBlank((String) nullsObj))) {
                vOrder.nullsParam = 'LAST';
            } else if (nullsObj instanceof String) {
                String nullsStr = ((String) nullsObj).toUpperCase();
                if ('FIRST'.equals(nullsStr)) {
                    vOrder.nullsParam = 'FIRST';
                } else if ('LAST'.equals(nullsStr)) {
                    vOrder.nullsParam = 'LAST';
                } else {
                    result.addError('OrderBy item ' + index + ' invalid "nulls": ' + nullsObj);
                    currentOrderValid = false;
                }
            } else {
                result.addError('OrderBy item ' + index + ' invalid type for "nulls": ' + nullsObj);
                currentOrderValid = false;
            }

            if (currentOrderValid && String.isNotBlank(vOrder.fieldPath)) {
                Boolean isSortable = false;
                if (!vOrder.fieldPath.contains('.')) {
                    isSortable = ContextUtils.isFieldSortable(targetSObjectType, vOrder.fieldPath);
                } else {
                    List<String> parts = vOrder.fieldPath.split('\\.');
                    if (parts.size() == 2) {
                        Map<String, Object> relValidation = ContextUtils.validateRelationshipField(
                            targetSObjectType,
                            parts[0],
                            parts[1],
                            'sortable'
                        );
                        isSortable = (Boolean) relValidation.get('isValid');
                        if (!isSortable)
                            result.addError(
                                'OrderBy item ' + index + ': ' + (String) relValidation.get('errorMessage')
                            );
                    } else {
                        result.addError(
                            'OrderBy item ' + index + ': Path "' + vOrder.fieldPath + '" has too many levels.'
                        );
                        currentOrderValid = false;
                    }
                }
                if (!isSortable && currentOrderValid) {
                    result.addError(
                        'OrderBy item ' +
                            index +
                            ': Field "' +
                            vOrder.fieldPath +
                            '" is invalid, inaccessible, or not sortable.'
                    );
                    currentOrderValid = false;
                }
            }

            if (String.isNotBlank(vOrder.fieldPath)) {
                result.validatedOrders.add(vOrder);
            }
        }
        return result;
    }

    public class ContextParseResult {
        public Boolean isValid = true;
        public List<String> errorMessages = new List<String>();
        public List<ValidatedCondition> validatedConditions = new List<ValidatedCondition>();
        public List<ValidatedOrder> validatedOrders = new List<ValidatedOrder>();
        public String conditionLogic = 'AND';

        public void addError(String message) {
            this.isValid = false;
            this.errorMessages.add(message);
        }
    }

    public class ValidatedCondition {
        public String fieldName;
        public String operator;
        public Object value;
    }

    public class ValidatedOrder {
        public String fieldPath;
        public String direction;
        public String nullsParam;
    }
}
