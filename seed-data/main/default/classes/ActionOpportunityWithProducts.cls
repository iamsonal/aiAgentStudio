/**
 * @description Complex composite action that creates an Opportunity with Products and a follow-up Task.
 *              Demonstrates transaction handling, reference linking, and configuration-driven behavior.
 * @extends BaseAgentAction
 */
public class ActionOpportunityWithProducts extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * Backend Configuration DTO
     */
    public class ConfigDTO {
        public Boolean allOrNone;                    // Transaction behavior
        public String defaultStage;                  // Default opportunity stage
        public String taskPriority;                  // Default task priority
        public String taskStatus;                    // Default task status
        public Integer taskDueDays;                  // Days until task is due
        public Boolean autoSetCloseDate;             // Auto-calculate close date
        public Integer closeDateDays;                // Days to add to today for close date
        public String pricebookId;                   // Pricebook2 ID for products
    }

    /**
     * Parameters DTO - Fields the LLM will populate
     */
    public class ParamsDTO {
        public OpportunityData opportunity;
        public List<ProductData> products;
        public TaskData followUpTask;
    }

    public class OpportunityData {
        public String name;
        public Id accountId;
        public Decimal amount;
        public String stageName;
        public Date closeDate;
        public String description;
        public String type;
        public String leadSource;
    }

    public class ProductData {
        public String productCode;          // Product2.ProductCode for lookup
        public Id product2Id;               // Or direct Product2 ID
        public Decimal quantity;
        public Decimal unitPrice;
        public String description;
    }

    public class TaskData {
        public String subject;
        public String description;
        public String priority;
        public String status;
        public Date activityDate;
    }

    /**
     * Result DTO
     */
    public class CompositeResult {
        @AuraEnabled public Id opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public Integer productCount;
        @AuraEnabled public List<Id> lineItemIds;
        @AuraEnabled public Id taskId;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public String message;

        public CompositeResult() {
            this.lineItemIds = new List<Id>();
            this.productCount = 0;
            this.totalAmount = 0;
        }
    }

    /**
     * @description Parses and validates backend configuration
     */
    private void parseConfiguration(String configJson) {
        try {
            this.config = new ConfigDTO();

            if (String.isBlank(configJson)) {
                // Set sensible defaults
                this.config.allOrNone = true;
                this.config.defaultStage = 'Prospecting';
                this.config.taskPriority = 'Normal';
                this.config.taskStatus = 'Not Started';
                this.config.taskDueDays = 7;
                this.config.autoSetCloseDate = true;
                this.config.closeDateDays = 30;
                return;
            }

            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(configJson);

            this.config.allOrNone = configMap.get('allOrNone') != null
                ? (Boolean) configMap.get('allOrNone') : true;
            this.config.defaultStage = (String) configMap.get('defaultStage');
            this.config.taskPriority = (String) configMap.get('taskPriority');
            this.config.taskStatus = (String) configMap.get('taskStatus');
            this.config.taskDueDays = configMap.get('taskDueDays') != null
                ? Integer.valueOf(configMap.get('taskDueDays')) : 7;
            this.config.autoSetCloseDate = configMap.get('autoSetCloseDate') != null
                ? (Boolean) configMap.get('autoSetCloseDate') : true;
            this.config.closeDateDays = configMap.get('closeDateDays') != null
                ? Integer.valueOf(configMap.get('closeDateDays')) : 30;
            this.config.pricebookId = (String) configMap.get('pricebookId');

        } catch (Exception e) {
            throw new ValidationException('Failed to parse backend configuration: ' + e.getMessage(), 'BackendConfiguration__c');
        }
    }

    /**
     * @description Main execution method
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Parse configuration
        parseConfiguration(this.parsedActionConfig != null ? JSON.serialize(this.parsedActionConfig) : '{}');

        // Parse and validate parameters
        ParamsDTO args = parseParameters(params);
        validateParameters(args);

        // Execute composite operation
        return executeCompositeOperation(args);
    }

    /**
     * @description Parses parameters into strongly-typed DTO
     */
    private ParamsDTO parseParameters(Map<String, Object> params) {
        ParamsDTO args = new ParamsDTO();

        // Parse opportunity data
        if (params.containsKey('opportunity')) {
            args.opportunity = parseOpportunityData((Map<String, Object>) params.get('opportunity'));
        }

        // Parse products array
        if (params.containsKey('products')) {
            args.products = new List<ProductData>();
            List<Object> productsRaw = (List<Object>) params.get('products');
            if (productsRaw != null) {
                for (Object prodObj : productsRaw) {
                    args.products.add(parseProductData((Map<String, Object>) prodObj));
                }
            }
        }

        // Parse task data
        if (params.containsKey('followUpTask')) {
            args.followUpTask = parseTaskData((Map<String, Object>) params.get('followUpTask'));
        }

        return args;
    }

    private OpportunityData parseOpportunityData(Map<String, Object> data) {
        OpportunityData opp = new OpportunityData();
        if (data == null) return opp;

        opp.name = (String) data.get('name');
        opp.accountId = (Id) data.get('accountId');
        opp.amount = data.get('amount') != null ? Decimal.valueOf(String.valueOf(data.get('amount'))) : null;
        opp.stageName = (String) data.get('stageName');
        opp.closeDate = data.get('closeDate') != null ? Date.valueOf(String.valueOf(data.get('closeDate'))) : null;
        opp.description = (String) data.get('description');
        opp.type = (String) data.get('type');
        opp.leadSource = (String) data.get('leadSource');

        return opp;
    }

    private ProductData parseProductData(Map<String, Object> data) {
        ProductData prod = new ProductData();
        if (data == null) return prod;

        prod.productCode = (String) data.get('productCode');
        prod.product2Id = (Id) data.get('product2Id');
        prod.quantity = data.get('quantity') != null ? Decimal.valueOf(String.valueOf(data.get('quantity'))) : 1;
        prod.unitPrice = data.get('unitPrice') != null ? Decimal.valueOf(String.valueOf(data.get('unitPrice'))) : 0;
        prod.description = (String) data.get('description');

        return prod;
    }

    private TaskData parseTaskData(Map<String, Object> data) {
        TaskData task = new TaskData();
        if (data == null) return task;

        task.subject = (String) data.get('subject');
        task.description = (String) data.get('description');
        task.priority = (String) data.get('priority');
        task.status = (String) data.get('status');
        task.activityDate = data.get('activityDate') != null ? Date.valueOf(String.valueOf(data.get('activityDate'))) : null;

        return task;
    }

    /**
     * @description Validates required parameters
     */
    private void validateParameters(ParamsDTO args) {
        if (args.opportunity == null) {
            throw new ValidationException('Opportunity data is required', 'opportunity');
        }

        if (String.isBlank(args.opportunity.name)) {
            throw new ValidationException('Opportunity name is required', 'opportunity.name');
        }

        if (args.opportunity.accountId == null) {
            throw new ValidationException('Account ID is required for the opportunity', 'opportunity.accountId');
        }

        // Validate products if provided
        if (args.products != null && !args.products.isEmpty()) {
            for (Integer i = 0; i < args.products.size(); i++) {
                ProductData prod = args.products[i];
                if (prod.product2Id == null && String.isBlank(prod.productCode)) {
                    throw new ValidationException(
                        'Product must have either product2Id or productCode specified',
                        'products[' + i + ']'
                    );
                }
            }
        }
    }

    /**
     * @description Executes the composite operation with transaction handling
     */
    private ActionOutcome executeCompositeOperation(ParamsDTO args) {
        CompositeResult result = new CompositeResult();
        Savepoint sp = config.allOrNone ? Database.setSavepoint() : null;

        try {
            // Step 1: Create Opportunity
            Opportunity opp = createOpportunity(args.opportunity);
            result.opportunityId = opp.Id;
            result.opportunityName = opp.Name;

            System.debug(LoggingLevel.INFO, '[ActionOpportunityWithProducts] Created Opportunity: ' + opp.Id);

            // Step 2: Create Opportunity Line Items (if products provided)
            if (args.products != null && !args.products.isEmpty()) {
                List<OpportunityLineItem> lineItems = createOpportunityLineItems(opp.Id, args.products);
                result.productCount = lineItems.size();
                for (OpportunityLineItem li : lineItems) {
                    result.lineItemIds.add(li.Id);
                    result.totalAmount += (li.Quantity * li.UnitPrice);
                }

                System.debug(LoggingLevel.INFO, '[ActionOpportunityWithProducts] Created ' + lineItems.size() + ' line items');
            }

            // Step 3: Create Follow-up Task (if provided)
            if (args.followUpTask != null && String.isNotBlank(args.followUpTask.subject)) {
                Task task = createFollowUpTask(opp.Id, args.followUpTask);
                result.taskId = task.Id;

                System.debug(LoggingLevel.INFO, '[ActionOpportunityWithProducts] Created Task: ' + task.Id);
            }

            // Build success message
            result.message = String.format(
                'Successfully created Opportunity "{0}" with {1} product(s) and follow-up task',
                new List<String>{ result.opportunityName, String.valueOf(result.productCount) }
            );

            return ActionOutcome.success(result);

        } catch (DmlException dmlEx) {
            if (sp != null) Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, '[ActionOpportunityWithProducts] DML Error: ' + dmlEx.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_DML_ERROR, 'Failed to create opportunity records: ' + dmlEx.getMessage());
        } catch (Exception ex) {
            if (sp != null) Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, '[ActionOpportunityWithProducts] Error: ' + ex.getMessage());
            throw ex; // Let BaseAgentAction handle exception mapping
        }
    }

    /**
     * @description Creates the Opportunity record
     */
    private Opportunity createOpportunity(OpportunityData data) {
        Opportunity opp = new Opportunity();

        // Required fields
        opp.Name = data.name;
        opp.AccountId = data.accountId;
        opp.StageName = String.isNotBlank(data.stageName) ? data.stageName : config.defaultStage;

        // Close date - use provided or auto-calculate
        if (data.closeDate != null) {
            opp.CloseDate = data.closeDate;
        } else if (config.autoSetCloseDate) {
            opp.CloseDate = Date.today().addDays(config.closeDateDays);
        } else {
            opp.CloseDate = Date.today().addDays(30); // Default 30 days
        }

        // Optional fields
        if (data.amount != null) {
            opp.Amount = data.amount;
        }
        if (String.isNotBlank(data.description)) {
            opp.Description = data.description;
        }
        if (String.isNotBlank(data.type)) {
            opp.Type = data.type;
        }
        if (String.isNotBlank(data.leadSource)) {
            opp.LeadSource = data.leadSource;
        }

        insert opp;
        return opp;
    }

    /**
     * @description Creates Opportunity Line Items (Products)
     */
    private List<OpportunityLineItem> createOpportunityLineItems(Id opportunityId, List<ProductData> products) {
        List<OpportunityLineItem> lineItems = new List<OpportunityLineItem>();

        // Get Pricebook Entry IDs
        Map<String, Id> productCodeToPricebookEntryId = new Map<String, Id>();
        Map<Id, Id> product2IdToPricebookEntryId = new Map<Id, Id>();

        Set<String> productCodes = new Set<String>();
        Set<Id> product2Ids = new Set<Id>();

        for (ProductData prod : products) {
            if (String.isNotBlank(prod.productCode)) {
                productCodes.add(prod.productCode);
            }
            if (prod.product2Id != null) {
                product2Ids.add(prod.product2Id);
            }
        }

        // Query PricebookEntry records
        String pricebookFilter = config.pricebookId != null
            ? 'AND Pricebook2Id = :config.pricebookId'
            : 'AND Pricebook2.IsStandard = TRUE';

        String query = 'SELECT Id, Product2Id, Product2.ProductCode FROM PricebookEntry ' +
                      'WHERE IsActive = TRUE ' + pricebookFilter;

        if (!productCodes.isEmpty()) {
            query += ' AND Product2.ProductCode IN :productCodes';
        }
        if (!product2Ids.isEmpty()) {
            query += ' AND Product2Id IN :product2Ids';
        }

        List<PricebookEntry> pricebookEntries = Database.query(query);

        for (PricebookEntry pbe : pricebookEntries) {
            if (String.isNotBlank(pbe.Product2.ProductCode)) {
                productCodeToPricebookEntryId.put(pbe.Product2.ProductCode, pbe.Id);
            }
            product2IdToPricebookEntryId.put(pbe.Product2Id, pbe.Id);
        }

        // Create line items
        for (ProductData prod : products) {
            OpportunityLineItem li = new OpportunityLineItem();
            li.OpportunityId = opportunityId;

            // Find PricebookEntry
            Id pricebookEntryId = null;
            if (prod.product2Id != null && product2IdToPricebookEntryId.containsKey(prod.product2Id)) {
                pricebookEntryId = product2IdToPricebookEntryId.get(prod.product2Id);
            } else if (String.isNotBlank(prod.productCode) && productCodeToPricebookEntryId.containsKey(prod.productCode)) {
                pricebookEntryId = productCodeToPricebookEntryId.get(prod.productCode);
            }

            if (pricebookEntryId == null) {
                String identifier = prod.product2Id != null ? String.valueOf(prod.product2Id) : prod.productCode;
                throw new ValidationException('Product not found in pricebook: ' + identifier, 'products');
            }

            li.PricebookEntryId = pricebookEntryId;
            li.Quantity = prod.quantity != null ? prod.quantity : 1;
            li.UnitPrice = prod.unitPrice != null ? prod.unitPrice : 0;

            if (String.isNotBlank(prod.description)) {
                li.Description = prod.description;
            }

            lineItems.add(li);
        }

        if (!lineItems.isEmpty()) {
            insert lineItems;
        }

        return lineItems;
    }

    /**
     * @description Creates a follow-up Task linked to the Opportunity
     */
    private Task createFollowUpTask(Id opportunityId, TaskData data) {
        Task task = new Task();

        task.WhatId = opportunityId;
        task.Subject = data.subject;
        task.Priority = String.isNotBlank(data.priority) ? data.priority : config.taskPriority;
        task.Status = String.isNotBlank(data.status) ? data.status : config.taskStatus;

        if (data.activityDate != null) {
            task.ActivityDate = data.activityDate;
        } else {
            task.ActivityDate = Date.today().addDays(config.taskDueDays);
        }

        if (String.isNotBlank(data.description)) {
            task.Description = data.description;
        }

        // Assign to original user who initiated the action
        task.OwnerId = actionContext.originalUserId;

        insert task;
        return task;
    }

    /**
     * @description Provides self-description with JSON schemas
     */
    public override ActionDescription describe() {
        return new AutoDescriptor()
            .loadFromMetadata('ActionOpportunityWithProducts')
            .setConfigFields(new List<FieldDescriptor>{
                FieldDescriptor.boolean('allOrNone')
                    .defaultTo('true')
                    .help('If true, all operations succeed or all fail (transaction rollback)'),
                FieldDescriptor.string('defaultStage')
                    .defaultTo('Prospecting')
                    .help('Default stage for new opportunities if not specified in parameters'),
                FieldDescriptor.string('taskPriority')
                    .defaultTo('Normal')
                    .help('Default priority for follow-up tasks (High, Normal, Low)'),
                FieldDescriptor.string('taskStatus')
                    .defaultTo('Not Started')
                    .help('Default status for follow-up tasks'),
                FieldDescriptor.integer('taskDueDays')
                    .defaultTo('7')
                    .help('Number of days from today when task should be due'),
                FieldDescriptor.boolean('autoSetCloseDate')
                    .defaultTo('true')
                    .help('Automatically calculate close date if not provided'),
                FieldDescriptor.integer('closeDateDays')
                    .defaultTo('30')
                    .help('Days to add to today for auto-calculated close date'),
                FieldDescriptor.string('pricebookId')
                    .help('Optional: Specific Pricebook2 ID. If not provided, uses standard pricebook')
            })
            .setParameterFields(new List<FieldDescriptor>{
                FieldDescriptor.object('opportunity')
                    .required()
                    .help('Opportunity details including name, account, amount, stage, and close date'),
                FieldDescriptor.array('products')
                    .help('Array of products to add to the opportunity. Each product needs productCode or product2Id'),
                FieldDescriptor.object('followUpTask')
                    .help('Optional follow-up task to create for the opportunity')
            })
            .toActionDescription();
    }
}

