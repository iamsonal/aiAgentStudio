/**
 * @description Demo action for retrieving Order records. Used by AgentTestDataFactory for showcasing agents.
 * Supports GET_BY_ID and SEARCH_BY_ACCOUNT operations with configurable fields.
 * 
 * @ActionLabel Get Order Details
 * @ActionDescription Demo action for retrieving Order records by ID or Account
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionIsStandard false
 * 
 * @extends BaseAgentAction
 */
public class ActionOrder extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Order ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldHelp The Salesforce ID of the Order to retrieve (for GET_BY_ID operation)
         */
        public String orderId;

        /**
         * @FieldLabel Account ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldHelp The Account ID to search Orders for (for SEARCH_BY_ACCOUNT operation)
         */
        public String accountId;
    }

    /**
     * DTO for strongly-typed backend configuration
     */
    public class ConfigDTO {
        /**
         * @FieldLabel Operation
         * @FieldType string
         * @FieldRequired true
         * @FieldHelp The operation to perform
         * @FieldPicklistValues GET_BY_ID,SEARCH_BY_ACCOUNT
         */
        public String operation;

        /**
         * @FieldLabel Default Fields
         * @FieldType array
         * @FieldRequired false
         * @FieldHelp List of field API names to return (default: Id, OrderNumber)
         */
        public List<String> defaultFields;

        /**
         * @FieldLabel Max Results
         * @FieldType integer
         * @FieldRequired false
         * @FieldHelp Maximum number of records to return for search operations
         * @FieldMinValue 1
         * @FieldMaxValue 200
         */
        public Integer maxResults;
    }

    /**
     * @description Main entry point for Order operations
     * @param params Raw parameters
     * @return ActionOutcome with Order data or error
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        ArgumentsDTO args = new ArgumentsDTO();
        args.orderId = (String) params.get('orderId');
        args.accountId = (String) params.get('accountId');

        if (config.operation == 'GET_BY_ID') {
            return getOrderById(args.orderId);
        } else if (config.operation == 'SEARCH_BY_ACCOUNT') {
            return searchOrdersByAccount(args.accountId);
        } else {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Unsupported operation: ' + config.operation
            );
        }
    }

    /**
     * Retrieves a single order by ID
     */
    private ActionOutcome getOrderById(String orderId) {
        if (String.isBlank(orderId)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'orderId is required for GET_BY_ID operation'
            );
        }

        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'OrderNumber' };

        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Order WHERE Id = :orderId LIMIT 1';
        
        try {
            List<Order> orders = Database.query(soql);
            if (orders.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                    'Order not found: ' + orderId
                );
            }

            return ActionOutcome.success(orders[0]);
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                'Error retrieving order: ' + e.getMessage()
            );
        }
    }

    /**
     * Searches for orders by account
     */
    private ActionOutcome searchOrdersByAccount(String accountId) {
        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'accountId is required for SEARCH_BY_ACCOUNT operation'
            );
        }

        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'OrderNumber' };

        Integer maxResults = config.maxResults != null ? config.maxResults : 10;
        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Order WHERE AccountId = :accountId LIMIT :maxResults';

        try {
            List<Order> orders = Database.query(soql);
            return ActionOutcome.success(new Map<String, Object>{
                'orders' => orders,
                'count' => orders.size(),
                'accountId' => accountId
            });
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                'Error searching orders: ' + e.getMessage()
            );
        }
    }

    /**
     * @description Parses action configuration JSON
     * @param actionConfigurationJson JSON configuration string
     * @param logPrefix Prefix for debug logging
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        this.config = new ConfigDTO();
        
        if (String.isBlank(actionConfigurationJson)) {
            this.config.operation = 'GET_BY_ID';
            this.config.defaultFields = new List<String>{ 'Id', 'OrderNumber' };
            this.config.maxResults = 10;
            return;
        }

        try {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);
            
            this.config.operation = (String) configMap.get('operation');
            
            if (configMap.containsKey('defaultFields')) {
                Object fieldsObj = configMap.get('defaultFields');
                if (fieldsObj instanceof List<Object>) {
                    this.config.defaultFields = new List<String>();
                    for (Object field : (List<Object>) fieldsObj) {
                        this.config.defaultFields.add(String.valueOf(field));
                    }
                }
            }
            
            if (configMap.containsKey('maxResults')) {
                Object maxResultsObj = configMap.get('maxResults');
                if (maxResultsObj instanceof Integer) {
                    this.config.maxResults = (Integer) maxResultsObj;
                } else if (maxResultsObj instanceof Decimal) {
                    this.config.maxResults = ((Decimal) maxResultsObj).intValue();
                }
            }
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage(), e);
        }

        if (String.isBlank(config.operation)) {
            config.operation = 'GET_BY_ID';
        }
        if (config.defaultFields == null) {
            config.defaultFields = new List<String>{ 'Id', 'OrderNumber' };
        }
        if (config.maxResults == null) {
            config.maxResults = 10;
        }
    }

}


