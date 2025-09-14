/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionSearchKnowledge is an advanced Apex action for intelligent Salesforce Knowledge Article search with pattern analysis, multi-language support, and robust scoring.
 *
 * Responsibilities:
 *   - Validates and extracts search parameters, including query, articleId, language, and result limits.
 *   - Performs advanced search optimization and pattern analysis for relevant Knowledge articles.
 *   - Supports multi-language search, draft inclusion, and intelligent scoring/ranking of results.
 *   - Returns structured, LLM-friendly result data and meaningful error messages for downstream use.
 *
 * Scope:
 *   - Strictly focused on secure, flexible Knowledge Article search and summarization.
 *   - Designed for maintainability, extensibility, and clarity, with detailed debug output and robust error handling.
 *
 * @extends BaseAgentAction
 */
public class ActionSearchKnowledge extends BaseAgentAction {
    private static final String CONFIG_DEFAULT_LANGUAGE = 'defaultLanguage';
    private static final String CONFIG_MAX_RESULTS = 'maxResults';
    private static final String CONFIG_SUMMARY_MAX_LENGTH = 'summaryMaxLength';

    private static final String DEFAULT_LANGUAGE = 'en_US';
    private static final Integer DEFAULT_MAX_RESULTS = 10;
    private static final Integer DEFAULT_SUMMARY_LENGTH = 1500;
    private static final Integer MAX_AMBIGUOUS_RESULTS = 5;

    // Knowledge-specific search patterns
    private static final Set<String> KNOWLEDGE_INDICATORS = new Set<String>{
        'how to',
        'guide',
        'tutorial',
        'help',
        'support',
        'faq',
        'troubleshoot',
        'problem',
        'issue',
        'error',
        'fix',
        'solution',
        'resolve',
        'configure',
        'setup',
        'install',
        'documentation',
        'manual',
        'procedure',
        'process'
    };

    private String defaultLanguage = DEFAULT_LANGUAGE;
    private Integer maxResults = DEFAULT_MAX_RESULTS;
    private Integer summaryMaxLength = DEFAULT_SUMMARY_LENGTH;

    /**
     * @description
     * Main entry point for Knowledge Article search. Validates parameters, analyzes patterns, executes search, scores results, and returns structured output.
     *
     * @param params Map<String, Object> - May include 'searchQuery', 'articleId', 'language', 'includeDrafts', 'maxResults'.
     * @return KnowledgeSearchResult - Contains found articles, options, and metadata.
     * @throws ValidationException for parameter or search errors.
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Extract and validate parameters
        String searchQuery = (String) params.get('searchQuery');
        Object articleIdObj = params.get('articleId');
        Id articleId = null;

        // Handle articleId parameter with proper validation
        if (articleIdObj != null) {
            if (articleIdObj instanceof Id) {
                articleId = (Id) articleIdObj;
            } else if (articleIdObj instanceof String && String.isNotBlank((String) articleIdObj)) {
                try {
                    articleId = Id.valueOf((String) articleIdObj);
                } catch (System.StringException strEx) {
                    // Invalid ID format - treat as if no articleId was provided
                    System.debug(LoggingLevel.WARN, '[ActionSearchKnowledge] Invalid articleId format provided: ' + articleIdObj);
                }
            }
        }

        String language = (String) params.get('language');
        Boolean includeDrafts = (Boolean) params.get('includeDrafts');
        Integer maxResultsParam = (Integer) params.get('maxResults');

        // Apply defaults and validation
        if (String.isBlank(searchQuery) && articleId == null) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Either "searchQuery" or "articleId" must be provided');
        }

        language = String.isNotBlank(language) ? language : this.defaultLanguage;
        includeDrafts = includeDrafts != null ? includeDrafts : false;
        Integer effectiveMaxResults = maxResultsParam != null ? Math.min(maxResultsParam, 50) : this.maxResults;

        System.debug(
            LoggingLevel.INFO,
            '[ActionSearchKnowledge] Starting Knowledge search. Query: "' +
                searchQuery +
                '", Language: ' +
                language +
                ', MaxResults: ' +
                effectiveMaxResults
        );

        // Execute search with enhanced error handling
        List<Knowledge__kav> articles;
        if (articleId != null) {
            articles = performDirectLookup(articleId, language, includeDrafts);
        } else {
            // Analyze search pattern for optimization
            SearchPatternAnalyzer.SearchAnalysis patternAnalysis = analyzeKnowledgeSearchPattern(searchQuery);
            articles = performIntelligentSearch(searchQuery, language, includeDrafts, effectiveMaxResults, patternAnalysis);
        }

        // Score and rank results
        List<ScoredKnowledgeResult> scoredResults = scoreAndRankKnowledgeResults(articles, searchQuery);

        // Process results and build response
        KnowledgeSearchResult searchResult = processKnowledgeResults(scoredResults, searchQuery);

        // Log performance metrics
        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionSearchKnowledge] Knowledge search completed in ' +
                executionTime +
                ' ms. Results: ' +
                (scoredResults != null ? scoredResults.size() : 0)
        );

        return ActionOutcome.success(searchResult);
    }

    /**
     * @description
     * Parses and validates the action configuration JSON. Extracts default language, max results, and summary length.
     *
     * @param actionConfigurationJson String - The JSON configuration string.
     * @param logPrefix String - Prefix for log output.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            this.defaultLanguage = ActionConfigUtils.getOptionalString(this.parsedActionConfig, CONFIG_DEFAULT_LANGUAGE) ?? DEFAULT_LANGUAGE;

            this.maxResults = ActionConfigUtils.getOptionalInteger(this.parsedActionConfig, CONFIG_MAX_RESULTS, DEFAULT_MAX_RESULTS);

            this.summaryMaxLength = ActionConfigUtils.getOptionalInteger(this.parsedActionConfig, CONFIG_SUMMARY_MAX_LENGTH, DEFAULT_SUMMARY_LENGTH);

            System.debug(
                LoggingLevel.INFO,
                '[ActionSearchKnowledge] Configuration loaded. Language: ' + this.defaultLanguage + ', MaxResults: ' + this.maxResults
            );
        }
    }

    /**
     * @description
     * Analyzes the search query for Knowledge-specific patterns to optimize search and scoring.
     *
     * @param searchQuery String - The search query string.
     * @return SearchPatternAnalyzer.SearchAnalysis - The pattern analysis result.
     */
    private SearchPatternAnalyzer.SearchAnalysis analyzeKnowledgeSearchPattern(String searchQuery) {
        SearchPatternAnalyzer.SearchAnalysis analysis = SearchPatternAnalyzer.analyzeSearchQuery(searchQuery);

        // Add Knowledge-specific pattern detection
        String normalizedQuery = searchQuery.toLowerCase();
        for (String indicator : KNOWLEDGE_INDICATORS) {
            if (normalizedQuery.contains(indicator)) {
                analysis.confidenceScore += 15; // Boost confidence for Knowledge patterns
                analysis.optimizationHints.add('Knowledge-specific pattern detected: ' + indicator);
                break;
            }
        }

        return analysis;
    }

    /**
     * @description
     * Performs direct Knowledge article lookup by ID.
     *
     * @param articleId Id - The Knowledge article Id.
     * @param language String - The language to filter by.
     * @param includeDrafts Boolean - Whether to include draft articles.
     * @return List<Knowledge__kav> - The found articles (max 1).
     */
    private List<Knowledge__kav> performDirectLookup(Id articleId, String language, Boolean includeDrafts) {
        // Use correct PublishStatus values
        String statusClause = includeDrafts ? 'PublishStatus IN (\'Draft\', \'Online\', \'Archived\')' : 'PublishStatus = \'Online\'';
        String fieldsToSelect = 'Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate, CreatedDate, PublishStatus, Language';

        String query =
            'SELECT ' +
            fieldsToSelect +
            ' FROM Knowledge__kav WHERE Id = :articleId AND ' +
            statusClause +
            ' AND Language = :language WITH USER_MODE LIMIT 1';

        return Database.query(query);
    }

    /**
     * @description
     * Performs intelligent SOSL search for Knowledge articles with pattern optimization.
     *
     * @param searchQuery String - The search query string.
     * @param language String - The language to filter by.
     * @param includeDrafts Boolean - Whether to include draft articles.
     * @param maxResults Integer - The maximum number of results to return.
     * @param patternAnalysis SearchPatternAnalyzer.SearchAnalysis - The pattern analysis result.
     * @return List<Knowledge__kav> - The found articles.
     * @throws QueryException if the search fails.
     */
    private List<Knowledge__kav> performIntelligentSearch(
        String searchQuery,
        String language,
        Boolean includeDrafts,
        Integer maxResults,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis
    ) {
        String fieldsToSelect = 'Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate, CreatedDate, PublishStatus, Language';
        // For SOSL, we'll filter by PublishStatus after the search to avoid syntax issues
        String baseQuery =
            'FIND :searchQuery IN ALL FIELDS RETURNING Knowledge__kav(' +
            fieldsToSelect +
            ' WHERE Language = :language' +
            ' ORDER BY LastModifiedDate DESC LIMIT ' +
            (maxResults * 2) + // Get more results to filter later
            ')';

        try {
            List<List<SObject>> searchResults = Search.query(baseQuery);
            List<Knowledge__kav> articles = (List<Knowledge__kav>) searchResults[0];

            // Filter by PublishStatus after the search
            if (!includeDrafts) {
                // Only include Online articles
                List<Knowledge__kav> filteredArticles = new List<Knowledge__kav>();
                for (Knowledge__kav article : articles) {
                    if (article.PublishStatus == 'Online') {
                        filteredArticles.add(article);
                    }
                }
                articles = filteredArticles;
            }
            // If includeDrafts is true, we keep all articles (Draft, Online, Archived)

            // Limit to maxResults
            if (articles.size() > maxResults) {
                List<Knowledge__kav> limitedArticles = new List<Knowledge__kav>();
                for (Integer i = 0; i < maxResults; i++) {
                    limitedArticles.add(articles[i]);
                }
                articles = limitedArticles;
            }

            return articles;
        } catch (SearchException se) {
            // Check if it's a language error and try with default language
            if (se.getMessage().contains('Invalid language code')) {
                // Try with default language
                baseQuery = baseQuery.replace(':language', '\'' + DEFAULT_LANGUAGE + '\'');
                try {
                    List<List<SObject>> fallbackResults = Search.query(baseQuery);
                    List<Knowledge__kav> articles = (List<Knowledge__kav>) fallbackResults[0];

                    // Apply same filtering logic
                    if (!includeDrafts) {
                        List<Knowledge__kav> filteredArticles = new List<Knowledge__kav>();
                        for (Knowledge__kav article : articles) {
                            if (article.PublishStatus == 'Online') {
                                filteredArticles.add(article);
                            }
                        }
                        articles = filteredArticles;
                    }

                    // Limit to maxResults
                    if (articles.size() > maxResults) {
                        List<Knowledge__kav> limitedArticles = new List<Knowledge__kav>();
                        for (Integer i = 0; i < maxResults; i++) {
                            limitedArticles.add(articles[i]);
                        }
                        articles = limitedArticles;
                    }

                    return articles;
                } catch (SearchException fallbackSe) {
                    throw new QueryException('Knowledge SOSL search failed: ' + fallbackSe.getMessage());
                }
            }
            throw new QueryException('Knowledge SOSL search failed: ' + se.getMessage());
        }
    }

    /**
     * @description
     * Scores and ranks Knowledge search results for relevance.
     *
     * @param articles List<Knowledge__kav> - The articles to score.
     * @param searchQuery String - The search query string.
     * @return List<ScoredKnowledgeResult> - The scored and ranked results.
     */
    private List<ScoredKnowledgeResult> scoreAndRankKnowledgeResults(List<Knowledge__kav> articles, String searchQuery) {
        if (articles == null || articles.isEmpty()) {
            return new List<ScoredKnowledgeResult>();
        }

        List<ScoredKnowledgeResult> scoredResults = new List<ScoredKnowledgeResult>();

        for (Integer i = 0; i < articles.size(); i++) {
            Knowledge__kav article = articles[i];
            Integer score = calculateKnowledgeRelevanceScore(article, searchQuery, i);
            scoredResults.add(new ScoredKnowledgeResult(article, score));
        }

        scoredResults.sort(); // Sort by score descending
        return scoredResults;
    }

    /**
     * @description
     * Calculates the relevance score for a Knowledge article based on query and recency.
     *
     * @param article Knowledge__kav - The article to score.
     * @param searchQuery String - The search query string.
     * @param soslPosition Integer - The position in the SOSL result set.
     * @return Integer - The calculated relevance score.
     */
    private Integer calculateKnowledgeRelevanceScore(Knowledge__kav article, String searchQuery, Integer soslPosition) {
        Integer score = 1000 - (soslPosition * 10); // Base SOSL relevance score

        if (String.isNotBlank(searchQuery)) {
            String queryLower = searchQuery.toLowerCase();

            // Title matching (highest weight)
            if (article.Title != null && article.Title.toLowerCase().contains(queryLower)) {
                score += 200;
                if (article.Title.toLowerCase().equals(queryLower)) {
                    score += 100; // Exact title match bonus
                }
            }

            // Summary matching
            if (article.Summary != null && article.Summary.toLowerCase().contains(queryLower)) {
                score += 100;
            }

            // Article number matching
            if (article.ArticleNumber != null && article.ArticleNumber.toLowerCase().contains(queryLower)) {
                score += 150;
            }
        }

        // Recency bonus (articles modified in last 30 days)
        if (article.LastModifiedDate != null && article.LastModifiedDate > DateTime.now().addDays(-30)) {
            score += 50;
        }

        return score;
    }

    /**
     * @description
     * Processes Knowledge search results and builds the response object.
     *
     * @param scoredResults List<ScoredKnowledgeResult> - The scored and ranked results.
     * @param searchQuery String - The original search query.
     * @return KnowledgeSearchResult - The structured result for downstream use.
     */
    private KnowledgeSearchResult processKnowledgeResults(List<ScoredKnowledgeResult> scoredResults, String searchQuery) {
        if (scoredResults.isEmpty()) {
            return new KnowledgeSearchResult(
                'NOT_FOUND',
                'I couldn\'t find any Knowledge articles matching your search. Try different keywords or check if the article exists.',
                null,
                null,
                searchQuery
            );
        }

        if (scoredResults.size() == 1 || hasDefinitiveBestMatch(scoredResults)) {
            Knowledge__kav article = scoredResults[0].article;
            String cleanSummary = article.Summary != null ? article.Summary.stripHtmlTags() : '';

            Map<String, Object> articleData = new Map<String, Object>{
                'id' => article.Id,
                'title' => article.Title,
                'articleNumber' => article.ArticleNumber,
                'summary' => cleanSummary.abbreviate(this.summaryMaxLength),
                'urlName' => article.UrlName,
                'lastModified' => article.LastModifiedDate,
                'publishStatus' => article.PublishStatus,
                'language' => article.Language,
                'relevanceScore' => scoredResults[0].score
            };

            String userMessage =
                'I found an article titled "' +
                article.Title +
                '". Here is a summary:\n\n' +
                cleanSummary.abbreviate(this.summaryMaxLength);

            return new KnowledgeSearchResult('SUCCESS', userMessage, articleData, null, searchQuery);
        } else {
            // Multiple results - return options
            List<Map<String, Object>> options = new List<Map<String, Object>>();

            for (Integer i = 0; i < Math.min(scoredResults.size(), MAX_AMBIGUOUS_RESULTS); i++) {
                Knowledge__kav article = scoredResults[i].article;
                String cleanSummary = article.Summary != null ? article.Summary.stripHtmlTags() : '';

                options.add(
                    new Map<String, Object>{
                        'id' => article.Id,
                        'title' => article.Title,
                        'articleNumber' => article.ArticleNumber,
                        'summary' => cleanSummary.abbreviate(this.summaryMaxLength),
                        'relevanceScore' => scoredResults[i].score,
                        'lastModified' => article.LastModifiedDate
                    }
                );
            }

            String userMessage = 'I found ' + scoredResults.size() + ' relevant articles. Please clarify which one you need:';
            return new KnowledgeSearchResult('AMBIGUOUS', userMessage, null, options, searchQuery);
        }
    }

    /**
     * @description
     * Determines if there is a definitive best match among the scored results.
     *
     * @param scoredResults List<ScoredKnowledgeResult> - The scored and ranked results.
     * @return Boolean - True if there is a clear best match.
     */
    private Boolean hasDefinitiveBestMatch(List<ScoredKnowledgeResult> scoredResults) {
        if (scoredResults.size() < 2)
            return true;

        Integer topScore = scoredResults[0].score;
        Integer secondScore = scoredResults[1].score;

        return (topScore - secondScore) > 100; // Significant score difference
    }

    /**
     * @description
     * Result wrapper for Knowledge search operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - resultType: String - The type of result (SUCCESS, AMBIGUOUS, NOT_FOUND).
     *   - message: String - User-facing message summarizing the result.
     *   - article: Map<String, Object> - The best-matching article (if any).
     *   - options: List<Map<String, Object>> - List of ambiguous options (if any).
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class KnowledgeSearchResult {
        public String resultType;
        public String message;
        public Map<String, Object> article;
        public List<Map<String, Object>> options;
        public Map<String, Object> metadata;

        public KnowledgeSearchResult(
            String resultType,
            String message,
            Map<String, Object> article,
            List<Map<String, Object>> options,
            String searchQuery
        ) {
            this.resultType = resultType;
            this.message = message;
            this.article = article;
            this.options = options;
            this.metadata = new Map<String, Object>{
                'searchType' => resultType,
                'searchQuery' => searchQuery,
                'hasArticle' => article != null,
                'optionCount' => options != null ? options.size() : 0,
                'searchSuccessful' => resultType != 'NOT_FOUND'
            };
        }
    }

    /**
     * @description
     * Scored Knowledge result for ranking and sorting.
     *
     * Fields:
     *   - article: Knowledge__kav - The Knowledge article.
     *   - score: Integer - The calculated relevance score.
     */
    private class ScoredKnowledgeResult implements Comparable {
        public Knowledge__kav article;
        public Integer score;

        public ScoredKnowledgeResult(Knowledge__kav article, Integer score) {
            this.article = article;
            this.score = score;
        }

        public Integer compareTo(Object other) {
            return ((ScoredKnowledgeResult) other).score - this.score; // Sort descending
        }
    }
}
