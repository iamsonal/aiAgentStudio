/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionSearchKnowledge is a streamlined and secure Apex action for searching Salesforce Knowledge articles.
 * It leverages the LLM to provide structured search parameters, eliminating the need for complex Apex-based
 * pattern analysis and scoring.
 *
 * Responsibilities:
 *   - Performs either a direct ID lookup or a keyword-based SOSL search for Knowledge__kav records.
 *   - Enforces security with USER_MODE queries and FLS checks.
 *   - Handles specific Knowledge parameters like language and draft status.
 *   - Returns a clean, structured list of found articles for the LLM to process.
 *
 * @extends BaseAgentAction
 */
public class ActionSearchKnowledge extends BaseAgentAction {
    private static final Integer MAX_QUERY_LIMIT = 20;
    private static final Integer DEFAULT_QUERY_LIMIT = 5;
    private static final String DEFAULT_LANGUAGE = 'en_US';

    // Configuration keys
    private static final String CONFIG_KEY_BODY_FIELDS = 'bodyFields';
    private static final String CONFIG_KEY_DEFAULT_INCLUDE_BODY = 'defaultIncludeBody';

    // Configuration populated during parseActionConfiguration
    private List<String> configuredBodyFields = new List<String>();
    private Boolean defaultIncludeBody = false;

    /**
     * @description
     * Main entry point for Knowledge search. The framework validates parameters against the JSON schema.
     *
     * @param params Map<String, Object> - Pre-validated parameters from the LLM.
     * @return ActionOutcome<KnowledgeSearchResult> - Contains found articles and metadata or a structured error.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // 1. Extract and validate parameters
        String searchQuery = (String) params.get('searchQuery');
        Id articleId = (Id) params.get('articleId');

        if (String.isBlank(searchQuery) && articleId == null) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Either "searchQuery" or "articleId" must be provided.');
        }

        String language = params.containsKey('language') ? (String) params.get('language') : DEFAULT_LANGUAGE;
        Boolean includeDrafts = params.containsKey('includeDrafts') ? (Boolean) params.get('includeDrafts') : false;
        Boolean includeBody = params.containsKey('includeBody') ? (Boolean) params.get('includeBody') : this.defaultIncludeBody;
        Integer limitValue = params.containsKey('maxResults') ? (Integer) params.get('maxResults') : DEFAULT_QUERY_LIMIT;
        Integer finalLimit = Math.min(limitValue, MAX_QUERY_LIMIT);

        // Build field list based on includeBody flag
        List<String> fieldsToQuery = buildFieldList(includeBody);

        try {
            List<Knowledge__kav> articles;

            // 2. Decide search path: Direct ID lookup or keyword search
            if (articleId != null) {
                System.debug(LoggingLevel.INFO, '[ActionSearchKnowledge] Performing direct lookup for Article ID: ' + articleId);
                articles = queryById(articleId, language, includeDrafts, fieldsToQuery);
            } else {
                System.debug(LoggingLevel.INFO, '[ActionSearchKnowledge] Performing keyword search for: "' + searchQuery + '"');
                articles = queryByKeywords(searchQuery, language, includeDrafts, finalLimit, fieldsToQuery);
            }

            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(
                LoggingLevel.INFO,
                '[ActionSearchKnowledge] Search completed in ' + executionTime + ' ms. Found ' + articles.size() + ' articles.'
            );

            // 3. Process and return results
            return ActionOutcome.success(new KnowledgeSearchResult(articles));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSearchKnowledge] Search failed: ' + e.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Knowledge search failed: ' + e.getMessage());
        }
    }

    /**
     * @description
     * Builds the list of fields to query based on includeBody flag and configuration.
     *
     * @param includeBody Whether to include body fields in the query
     * @return List of field API names to query
     */
    private List<String> buildFieldList(Boolean includeBody) {
        // Always include base metadata fields
        List<String> fields = new List<String>{
            'Id',
            'Title',
            'ArticleNumber',
            'Summary',
            'UrlName',
            'LastModifiedDate',
            'PublishStatus'
        };

        // Add body fields if requested and configured
        if (includeBody && !this.configuredBodyFields.isEmpty()) {
            fields.addAll(this.configuredBodyFields);
            System.debug(
                LoggingLevel.DEBUG,
                '[ActionSearchKnowledge] Including body fields in query: ' + String.join(this.configuredBodyFields, ', ')
            );
        }

        return fields;
    }

    /**
     * @description
     * Performs a secure SOQL query to find a specific Knowledge article by its ID.
     *
     * @param articleId    The Knowledge article ID to retrieve
     * @param language     The language of the article
     * @param includeDrafts Whether to include draft articles
     * @param fields       List of fields to retrieve
     * @return List of matching Knowledge articles
     */
    private List<Knowledge__kav> queryById(Id articleId, String language, Boolean includeDrafts, List<String> fields) {
        String soqlQuery =
            'SELECT ' + String.join(fields, ', ') + ' ' +
            'FROM Knowledge__kav ' +
            'WHERE Id = :articleId AND Language = :language';

        if (includeDrafts) {
            soqlQuery += ' AND PublishStatus IN (\'Draft\', \'Online\', \'Archived\')';
        } else {
            soqlQuery += ' AND PublishStatus = \'Online\'';
        }

        soqlQuery += ' WITH USER_MODE LIMIT 1';
        return Database.query(soqlQuery);
    }

    /**
     * @description
     * Performs a secure SOSL query for Knowledge articles based on keywords.
     *
     * @param searchQuery   The search term(s) to find
     * @param language      The language of articles to search
     * @param includeDrafts Whether to include draft articles
     * @param limitValue    Maximum number of results to return
     * @param fields        List of fields to retrieve
     * @return List of matching Knowledge articles
     */
    private List<Knowledge__kav> queryByKeywords(String searchQuery, String language, Boolean includeDrafts, Integer limitValue, List<String> fields) {
        String sanitizedQuery = String.escapeSingleQuotes(searchQuery);
        String fieldList = String.join(fields, ', ');

        String soslQuery =
            'FIND \'' +
            sanitizedQuery +
            '\' IN ALL FIELDS ' +
            'RETURNING Knowledge__kav(' + fieldList + ' WHERE Language = \'' +
            language +
            '\') ' +
            'LIMIT ' +
            limitValue;

        List<List<SObject>> searchResults = Search.query(soslQuery);
        List<Knowledge__kav> articles = (List<Knowledge__kav>) searchResults[0];

        // Post-filter for draft status if needed
        if (!includeDrafts) {
            List<Knowledge__kav> onlineArticles = new List<Knowledge__kav>();
            for (Knowledge__kav article : articles) {
                if (article.PublishStatus == 'Online') {
                    onlineArticles.add(article);
                }
            }
            return onlineArticles;
        }

        return articles;
    }

    /**
     * @description
     * Parses action configuration to support optional body field retrieval.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            // Load configured body fields if specified
            this.configuredBodyFields = ActionConfigUtils.getOptionalStringList(this.parsedActionConfig, CONFIG_KEY_BODY_FIELDS);
            this.defaultIncludeBody = ActionConfigUtils.getOptionalBoolean(this.parsedActionConfig, CONFIG_KEY_DEFAULT_INCLUDE_BODY, false);

            if (!this.configuredBodyFields.isEmpty()) {
                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix + 'Loaded ' + this.configuredBodyFields.size() + ' body fields from configuration: ' +
                    String.join(this.configuredBodyFields, ', ')
                );
            }
        }
    }

    /**
     * @description
     * Result wrapper for the knowledge search operation. This is what the LLM will receive.
     */
    public class KnowledgeSearchResult {
        @AuraEnabled
        public List<Map<String, Object>> articles;
        @AuraEnabled
        public Integer count;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Map<String, Object> metadata;

        public KnowledgeSearchResult(List<Knowledge__kav> kavs) {
            this.articles = new List<Map<String, Object>>();
            for (Knowledge__kav kav : kavs) {
                Map<String, Object> articleMap = new Map<String, Object>();

                // Get all populated fields from the SObject
                Map<String, Object> populatedFields = kav.getPopulatedFieldsAsMap();

                for (String fieldName : populatedFields.keySet()) {
                    Object fieldValue = populatedFields.get(fieldName);

                    // Strip HTML tags from rich text fields
                    if (fieldValue instanceof String) {
                        String strValue = (String) fieldValue;
                        // Check if field likely contains HTML
                        if (strValue.contains('<') && strValue.contains('>')) {
                            fieldValue = strValue.stripHtmlTags();
                        }
                    }

                    // Convert field name to camelCase for consistency
                    String camelCaseField = toCamelCase(fieldName);
                    articleMap.put(camelCaseField, fieldValue);
                }

                this.articles.add(articleMap);
            }
            this.count = articles.size();
            this.message = 'Found ' + this.count + ' knowledge article(s).';
            this.metadata = new Map<String, Object>{ 'totalFound' => this.count };
        }

        /**
         * @description
         * Converts field API name to camelCase for JSON consistency.
         *
         * @param fieldApiName The field API name (e.g., ArticleNumber, Article_Body__c)
         * @return camelCase version (e.g., articleNumber, articleBody)
         */
        private String toCamelCase(String fieldApiName) {
            if (String.isBlank(fieldApiName)) {
                return fieldApiName;
            }

            // Remove __c suffix if present
            String cleaned = fieldApiName.replace('__c', '');

            // Handle underscores (e.g., Article_Body -> articleBody)
            if (cleaned.contains('_')) {
                List<String> parts = cleaned.split('_');
                String result = parts[0].toLowerCase();
                for (Integer i = 1; i < parts.size(); i++) {
                    result += parts[i].capitalize();
                }
                return result;
            }

            // Just lowercase first character for standard fields
            return cleaned.substring(0, 1).toLowerCase() + cleaned.substring(1);
        }
    }
}
