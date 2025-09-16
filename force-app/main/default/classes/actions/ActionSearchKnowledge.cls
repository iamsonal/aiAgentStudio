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
        Integer limitValue = params.containsKey('maxResults') ? (Integer) params.get('maxResults') : DEFAULT_QUERY_LIMIT;
        Integer finalLimit = Math.min(limitValue, MAX_QUERY_LIMIT);

        try {
            List<Knowledge__kav> articles;

            // 2. Decide search path: Direct ID lookup or keyword search
            if (articleId != null) {
                System.debug(LoggingLevel.INFO, '[ActionSearchKnowledge] Performing direct lookup for Article ID: ' + articleId);
                articles = queryById(articleId, language, includeDrafts);
            } else {
                System.debug(LoggingLevel.INFO, '[ActionSearchKnowledge] Performing keyword search for: "' + searchQuery + '"');
                articles = queryByKeywords(searchQuery, language, includeDrafts, finalLimit);
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
     * Performs a secure SOQL query to find a specific Knowledge article by its ID.
     */
    private List<Knowledge__kav> queryById(Id articleId, String language, Boolean includeDrafts) {
        String soqlQuery =
            'SELECT Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate ' +
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
     */
    private List<Knowledge__kav> queryByKeywords(String searchQuery, String language, Boolean includeDrafts, Integer limitValue) {
        String sanitizedQuery = String.escapeSingleQuotes(searchQuery);
        String soslQuery =
            'FIND \'' +
            sanitizedQuery +
            '\' IN ALL FIELDS ' +
            'RETURNING Knowledge__kav(Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate, PublishStatus WHERE Language = \'' +
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
     * @description No static configuration is needed as parameters are provided by the LLM.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // This action is fully dynamic; no backend configuration is necessary.
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
                this.articles.add(
                    new Map<String, Object>{
                        'id' => kav.Id,
                        'title' => kav.Title,
                        'articleNumber' => kav.ArticleNumber,
                        'summary' => kav.Summary != null ? kav.Summary.stripHtmlTags() : null,
                        'urlName' => kav.UrlName,
                        'lastModifiedDate' => kav.LastModifiedDate
                    }
                );
            }
            this.count = articles.size();
            this.message = 'Found ' + this.count + ' knowledge article(s).';
            this.metadata = new Map<String, Object>{ 'totalFound' => this.count };
        }
    }
}
