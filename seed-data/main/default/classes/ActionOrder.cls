/**
 * @description Demo action for retrieving Order records. Used by AgentTestDataFactory for showcasing agents.
 * Supports get_by_id and search_by_account variants with configurable fields.
 *
 * @ActionLabel Get Order Details
 * @ActionDescription Demo action for retrieving Order records by ID or Account
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionIsStandard false
 * @ActionHasVariants true
 * @ActionVariant get_by_id | Get by ID | Retrieve a single Order record by its Salesforce ID
 * @ActionVariant search_by_account | Search by Account | Find all Orders belonging to a given Account
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
         * @FieldVariant get_by_id
         * @FieldHelp The Salesforce ID of the Order to retrieve
         */
        public String orderId;

        /**
         * @FieldLabel Account ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldVariant search_by_account
         * @FieldHelp The Account ID to find all related Orders for
         */
        public String accountId;
    }

    /**
     * DTO for strongly-typed backend configuration
     */
    public class ConfigDTO {
        /**
         * @FieldSystem true
         * @FieldLabel Variant
         * @FieldType string
         * @FieldHelp Operating mode: "get_by_id" or "search_by_account". Managed by the variant picker UI.
         */
        public String variant;

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
         * @FieldVariant search_by_account
         * @FieldHelp Maximum number of Orders to return
         * @FieldMinValue 1
         * @FieldMaxValue 200
         */
        public Integer maxResults;
    }

    /**
     * @description Main entry point — dispatches to the configured variant
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        ArgumentsDTO args = new ArgumentsDTO();
        args.orderId = (String) params.get('orderId');
        args.accountId = (String) params.get('accountId');

        if ('get_by_id'.equals(config.variant)) {
            return getOrderById(args.orderId);
        } else if ('search_by_account'.equals(config.variant)) {
            return searchOrdersByAccount(args.accountId);
        } else {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Unsupported variant: "' + config.variant + '"');
        }
    }

    private ActionOutcome getOrderById(String orderId) {
        if (String.isBlank(orderId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, '"orderId" is required for the get_by_id variant');
        }

        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'OrderNumber' };

        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Order WHERE Id = :orderId LIMIT 1';

        try {
            List<Order> orders = Database.query(soql);
            if (orders.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Order not found: ' + orderId);
            }
            return ActionOutcome.success(orders[0]);
        } catch (Exception e) {
            return ActionOutcome.fromException(e);
        }
    }

    private ActionOutcome searchOrdersByAccount(String accountId) {
        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, '"accountId" is required for the search_by_account variant');
        }

        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'OrderNumber' };

        Integer maxResults = config.maxResults != null ? config.maxResults : 10;
        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Order WHERE AccountId = :accountId LIMIT :maxResults';

        try {
            List<Order> orders = Database.query(soql);
            return ActionOutcome.success(new Map<String, Object>{ 'orders' => orders, 'count' => orders.size(), 'accountId' => accountId });
        } catch (Exception e) {
            return ActionOutcome.fromException(e);
        }
    }

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        this.config = new ConfigDTO();

        if (String.isBlank(actionConfigurationJson)) {
            this.config.variant = 'get_by_id';
            this.config.defaultFields = new List<String>{ 'Id', 'OrderNumber' };
            this.config.maxResults = 10;
            return;
        }

        try {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            this.config.variant = ActionConfigUtils.getOptionalString(configMap, 'variant');
            this.config.defaultFields = ActionConfigUtils.getOptionalStringList(configMap, 'defaultFields');

            if (configMap.containsKey('maxResults')) {
                Object maxResultsObj = configMap.get('maxResults');
                if (maxResultsObj instanceof Integer) {
                    this.config.maxResults = (Integer) maxResultsObj;
                } else if (maxResultsObj instanceof Decimal) {
                    this.config.maxResults = ((Decimal) maxResultsObj).intValue();
                }
            }
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage(), null, e);
        }

        if (String.isBlank(config.variant)) {
            config.variant = 'get_by_id';
        }
        if (config.defaultFields == null || config.defaultFields.isEmpty()) {
            config.defaultFields = new List<String>{ 'Id', 'OrderNumber' };
        }
        if (config.maxResults == null) {
            config.maxResults = 10;
        }
    }
}
