/**
 * @description Demo action for retrieving Account records. Used by AgentTestDataFactory for showcasing agents.
 * Supports GET_BY_ID and SEARCH operations with configurable fields.
 * 
 * @ActionLabel Get Account Details
 * @ActionDescription Demo action for retrieving Account records by ID or search term
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionIsStandard false
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
         * @FieldHelp The Salesforce ID of the Account to retrieve (for GET_BY_ID operation)
         */
        public String accountId;

        /**
         * @FieldLabel Search Term
         * @FieldType string
         * @FieldRequired false
         * @FieldHelp Search term to find Accounts by name (for SEARCH operation)
         */
        public String searchTerm;
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
         * @FieldHelp List of field API names to return (default: Id, Name)
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
     * @description Main entry point for Account operations
     * @param params Raw parameters
     * @return ActionOutcome with Account data or error
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        ArgumentsDTO args = new ArgumentsDTO();
        args.accountId = (String) params.get('accountId');
        args.searchTerm = (String) params.get('searchTerm');

        if (config.operation == 'GET_BY_ID') {
            return getAccountById(args.accountId);
        } else if (config.operation == 'SEARCH_BY_ACCOUNT') {
            return searchAccounts(args.searchTerm);
        } else {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Unsupported operation: ' + config.operation
            );
        }
    }

    /**
     * Retrieves a single account by ID
     */
    private ActionOutcome getAccountById(String accountId) {
        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'accountId is required for GET_BY_ID operation'
            );
        }

        List<String> fields = config.defaultFields != null && !config.defaultFields.isEmpty()
            ? config.defaultFields
            : new List<String>{ 'Id', 'Name' };

        String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM Account WHERE Id = :accountId LIMIT 1';
        
        try {
            List<Account> accounts = Database.query(soql);
            if (accounts.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                    'Account not found: ' + accountId
                );
            }

            return ActionOutcome.success(accounts[0]);
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                'Error retrieving account: ' + e.getMessage()
            );
        }
    }

    /**
     * Searches for accounts by name or other criteria
     */
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
            return ActionOutcome.success(new Map<String, Object>{
                'accounts' => accounts,
                'count' => accounts.size()
            });
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                'Error searching accounts: ' + e.getMessage()
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
            this.config.defaultFields = new List<String>{ 'Id', 'Name' };
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
            config.defaultFields = new List<String>{ 'Id', 'Name' };
        }
        if (config.maxResults == null) {
            config.maxResults = 10;
        }
    }

}


