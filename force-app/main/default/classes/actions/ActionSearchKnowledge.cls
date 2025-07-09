/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Searches for Salesforce Knowledge Articles.
 *              Uses SOSL for keyword searches and supports filtering by data categories.
 *              Can also retrieve a specific article by its ID.
 *              Returns a single article with a summary, or a list of ambiguous results.
 * @extends BaseAgentAction
 */
public class ActionSearchKnowledge extends BaseAgentAction {
    private static final String ARG_SEARCH_QUERY = 'searchQuery';
    private static final String ARG_ARTICLE_ID = 'articleId';
    private static final String ARG_DATA_CATEGORY = 'dataCategory';
    private static final Integer MAX_RESULTS_FOR_AMBIGUOUS = 5;
    private static final Integer SUMMARY_MAX_LENGTH = 1500;

    private static final String STATUS_SUCCESS = 'SUCCESS';
    private static final String STATUS_AMBIGUOUS = 'AMBIGUOUS';
    private static final String STATUS_NOT_FOUND = 'NOT_FOUND';

    protected override String getLogPrefixName() {
        return 'ActionSearchKnowledge';
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Inner class to hold parsed and validated arguments from the LLM.
     */
    private class SearchKnowledgeArgs extends BaseAgentAction.ParsedArguments {
        String searchQuery;
        Id articleId;
        Map<String, String> dataCategories;

        public SearchKnowledgeArgs(String jsonArguments) {
            Map<String, Object> parsedArgs = String.isNotBlank(jsonArguments)
                ? (Map<String, Object>) JSON.deserializeUntyped(jsonArguments)
                : new Map<String, Object>();

            this.searchQuery = ParameterExtractionUtils.getOptionalString(parsedArgs, ARG_SEARCH_QUERY);
            this.articleId = ParameterExtractionUtils.getOptionalId(parsedArgs, ARG_ARTICLE_ID, Knowledge__kav.SObjectType);

            if (String.isBlank(this.searchQuery) && this.articleId == null) {
                throw new ValidationException('Either "' + ARG_SEARCH_QUERY + '" or "' + ARG_ARTICLE_ID + '" must be provided.', null);
            }

            this.dataCategories = new Map<String, String>();
            if (parsedArgs.get(ARG_DATA_CATEGORY) instanceof Map<String, Object>) {
                Map<String, Object> rawCategories = (Map<String, Object>) parsedArgs.get(ARG_DATA_CATEGORY);
                for (String key : rawCategories.keySet()) {
                    if (rawCategories.get(key) instanceof String) {
                        this.dataCategories.put(key, (String) rawCategories.get(key));
                    }
                }
            }
        }
    }

    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        try {
            return new SearchKnowledgeArgs(argumentsJson);
        } catch (Exception e) {
            throw new ValidationException('Failed to parse arguments for Knowledge search: ' + e.getMessage(), null, e);
        }
    }

    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        SearchKnowledgeArgs args = (SearchKnowledgeArgs) validatedArgs;
        List<Knowledge__kav> articles;

        if (args.articleId != null) {
            articles = [
                SELECT Id, Title, ArticleNumber, Summary, UrlName
                FROM Knowledge__kav
                WHERE Id = :args.articleId AND PublishStatus = 'Online' AND Language = 'en_US'
                WITH USER_MODE
                LIMIT 1
            ];
        } else {
            String searchQuery = args.searchQuery;

            String soslQuery = 'FIND :searchQuery IN ALL FIELDS RETURNING Knowledge__kav(Id, Title, ArticleNumber, Summary, UrlName WHERE PublishStatus=\'Online\' AND Language=\'en_US\'';

            String categoryClause = buildDataCategoryClause(args.dataCategories);
            if (String.isNotBlank(categoryClause)) {
                soslQuery += ' ' + categoryClause;
            }
            soslQuery += ')';

            List<List<SObject>> searchResults = Search.query(soslQuery);
            articles = (List<Knowledge__kav>) searchResults[0];
        }

        Knowledge__kav bestMatch = findBestMatch(articles, args.searchQuery);
        if (bestMatch != null) {
            Map<String, Object> result = buildSuccessResult(bestMatch);
            return this.success(
                (Map<String, Object>) result.get('data'),
                (String) result.get('messageForUser'),
                (String) result.get('internalDetails')
            );
        } else if (articles.size() == 1) {
            Map<String, Object> result = buildSuccessResult(articles[0]);
            return this.success(
                (Map<String, Object>) result.get('data'),
                (String) result.get('messageForUser'),
                (String) result.get('internalDetails')
            );
        } else {
            Map<String, Object> result = buildAmbiguousResult(articles);
            return this.success(
                (Map<String, Object>) result.get('data'),
                (String) result.get('messageForUser'),
                (String) result.get('internalDetails')
            );
        }
    }

    /**
     * @description Builds the 'WITH DATA CATEGORY' clause for the SOSL query.
     */
    private String buildDataCategoryClause(Map<String, String> categories) {
        if (categories == null || categories.isEmpty()) {
            return '';
        }
        List<String> categoryPairs = new List<String>();
        for (String grp : categories.keySet()) {
            if (Pattern.matches('^[a-zA-Z0-9_]+$', grp)) {
                categoryPairs.add(grp + ' AT \'' + String.escapeSingleQuotes(categories.get(grp)) + '\'');
            }
        }
        return categoryPairs.isEmpty() ? '' : 'WITH DATA CATEGORY ' + String.join(categoryPairs, ' AND ');
    }

    /**
     * @description Creates a successful ActionResult with a single, summarized article.
     */
    private Map<String, Object> buildSuccessResult(Knowledge__kav article) {
        String cleanSummary = (article.Summary != null) ? article.Summary.stripHtmlTags() : '';
        Map<String, Object> dataPayload = new Map<String, Object>{
            'status' => STATUS_SUCCESS,
            'article' => new Map<String, Object>{
                'id' => article.Id,
                'title' => article.Title,
                'articleNumber' => article.ArticleNumber,
                'summary' => cleanSummary.abbreviate(SUMMARY_MAX_LENGTH)
            }
        };
        return new Map<String, Object>{
            'data' => dataPayload,
            'messageForUser' => 'I found an article titled "' +
            article.Title +
            '". Here is a summary:\n\n' +
            cleanSummary.abbreviate(SUMMARY_MAX_LENGTH),
            'internalDetails' => 'Found single matching article: ' + article.ArticleNumber
        };
    }

    /**
     * @description Creates an ambiguous ActionResult with a list of choices for the user.
     */
    private Map<String, Object> buildAmbiguousResult(List<Knowledge__kav> articles) {
        List<Map<String, Object>> options = new List<Map<String, Object>>();
        for (Integer i = 0; i < Math.min(articles.size(), MAX_RESULTS_FOR_AMBIGUOUS); i++) {
            Knowledge__kav article = articles[i];
            String cleanSummary = (article.Summary != null) ? article.Summary.stripHtmlTags() : '';
            options.add(
                new Map<String, Object>{
                    'id' => article.Id,
                    'title' => article.Title,
                    'articleNumber' => article.ArticleNumber,
                    'summary' => cleanSummary.abbreviate(SUMMARY_MAX_LENGTH)
                }
            );
        }
        Map<String, Object> dataPayload = new Map<String, Object>{ 'status' => STATUS_AMBIGUOUS, 'options' => options };
        return new Map<String, Object>{
            'data' => dataPayload,
            'messageForUser' => 'I found multiple relevant articles. The agent should present these options to the user for clarification.',
            'internalDetails' => 'Found ' +
            articles.size() +
            ' ambiguous results. Returning top ' +
            options.size() +
            ' as choices.'
        };
    }

    private Knowledge__kav findBestMatch(List<Knowledge__kav> articles, String searchQuery) {
        if (articles == null || articles.size() <= 1 || String.isBlank(searchQuery)) {
            return null;
        }
        for (Knowledge__kav article : articles) {
            if (article.Title != null && article.Title.toLowerCase().contains(searchQuery.toLowerCase())) {
                return article;
            }
        }
        return null;
    }
}
