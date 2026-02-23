/**
 * @description Demo action for retrieving Account records. Used by AgentTestDataFactory for showcasing agents.
 * Supports get_by_id and search variants with configurable fields.
 *
 * @ActionLabel Get Account Details
 * @ActionDescription Demo action for retrieving Account records by ID or name search
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionIsStandard false
 * @ActionHasVariants true
 * @ActionVariant get_by_id | Get by ID | Retrieve a single Account record by its Salesforce ID
 * @ActionVariant search | Search Accounts | Find Accounts by name or other search criteria
 *
 * @extends BaseAgentAction
 */
public class ActionAccount extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Account ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldVariant get_by_id
         * @FieldHelp The Salesforce ID of the Account to retrieve
         */
        public String accountId;

        /**
         * @FieldLabel Search Term
         * @FieldType string
         * @FieldRequired false
         * @FieldVariant search
         * @FieldHelp Name or partial name to search for Accounts
         */
        public String searchTerm;
    }

    /**
     * DTO for strongly-typed backend configuration
     */
    public class ConfigDTO {
        /**
         * @FieldSystem true
         * @FieldLabel Variant
         * @FieldType string
         * @FieldHelp Operating mode: "get_by_id" or "search". Managed by the variant picker UI.
         */
        public String variant;

        /**
         * @FieldLabel Default Fields
         * @FieldType array
         * @FieldRequired false
         * @FieldHelp List of field API names to return (default: Id, Name)
         */
        public List<String> defaultFields;

        /**
         * @FieldLabel Max Results
         * @FieldType integer
         * @FieldRequired false
         * @FieldVariant search
         * @FieldHelp Maximum number of Accounts to return
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
        args.accountId = (String) params.get('accountId');
        args.searchTerm = (String) params.get('searchTerm');

        if ('get_by_id'.equals(config.variant)) {
            return getAccountById(args.accountId);
        } else if ('search'.equals(config.variant)) {
            return searchAccounts(args.searchTerm);
        } else {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Unsupported variant: "' + config.variant + '"');
        }
    }

    private ActionOutcome getAccountById(String accountId) {
        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, '"accountId" is required for the get_by_id variant');
        }

        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'Name' };

        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Account WHERE Id = :accountId LIMIT 1';

        try {
            List<Account> accounts = Database.query(soql);
            if (accounts.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Account not found: ' + accountId);
            }
            return ActionOutcome.success(accounts[0]);
        } catch (Exception e) {
            return ActionOutcome.fromException(e);
        }
    }

    private ActionOutcome searchAccounts(String searchTerm) {
        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'Name' };

        Integer maxResults = config.maxResults != null ? config.maxResults : 10;
        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Account';

        if (String.isNotBlank(searchTerm)) {
            soql += ' WHERE Name LIKE :searchTerm';
            searchTerm = '%' + searchTerm + '%';
        }

        soql += ' LIMIT :maxResults';

        try {
            List<Account> accounts = Database.query(soql);
            return ActionOutcome.success(new Map<String, Object>{ 'accounts' => accounts, 'count' => accounts.size() });
        } catch (Exception e) {
            return ActionOutcome.fromException(e);
        }
    }

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        this.config = new ConfigDTO();

        if (String.isBlank(actionConfigurationJson)) {
            this.config.variant = 'get_by_id';
            this.config.defaultFields = new List<String>{ 'Id', 'Name' };
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
            config.defaultFields = new List<String>{ 'Id', 'Name' };
        }
        if (config.maxResults == null) {
            config.maxResults = 10;
        }
    }
}
