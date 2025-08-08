/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Intelligent Salesforce Knowledge Article Search with pattern analysis.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *
 *              MAINTAINS: Advanced search optimization, multi-language support, and intelligent scoring.
 *              ENHANCED: Simplified interface while preserving all advanced search features.
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
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains advanced Knowledge search while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        String searchQuery = (String) params.get('searchQuery');
        Id articleId = (Id) params.get('articleId');
        String language = (String) params.get('language');
        Boolean includeDrafts = (Boolean) params.get('includeDrafts');
        Integer maxResultsParam = (Integer) params.get('maxResults');

        if (String.isBlank(searchQuery) && articleId == null) {
            throw new ValidationException('Either "searchQuery" or "articleId" must be provided', null);
        }

        language = String.isNotBlank(language) ? language : this.defaultLanguage;
        includeDrafts = includeDrafts != null ? includeDrafts : false;
        Integer effectiveMaxResults = maxResultsParam != null ? Math.min(maxResultsParam, 50) : this.maxResults;

        List<Knowledge__kav> articles;
        if (articleId != null) {
            articles = performDirectLookup(articleId, language, includeDrafts);
        } else {
            SearchPatternAnalyzer.SearchAnalysis patternAnalysis = analyzeKnowledgeSearchPattern(searchQuery);
            articles = performIntelligentSearch(searchQuery, language, includeDrafts, effectiveMaxResults, patternAnalysis);
        }

        List<ScoredKnowledgeResult> scoredResults = scoreAndRankKnowledgeResults(articles, searchQuery);

        KnowledgeSearchResult result = processKnowledgeResults(scoredResults, searchQuery);

        Long executionTime = System.currentTimeMillis() - startTime;

        return result;
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            this.defaultLanguage = (String) this.parsedActionConfig.get(CONFIG_DEFAULT_LANGUAGE) ?? DEFAULT_LANGUAGE;
            this.maxResults = (Integer) this.parsedActionConfig.get(CONFIG_MAX_RESULTS) ?? DEFAULT_MAX_RESULTS;
            this.summaryMaxLength = (Integer) this.parsedActionConfig.get(CONFIG_SUMMARY_MAX_LENGTH) ?? DEFAULT_SUMMARY_LENGTH;
        }
    }

    /**
     * @description Analyzes search query with Knowledge-specific patterns
     */
    private SearchPatternAnalyzer.SearchAnalysis analyzeKnowledgeSearchPattern(String searchQuery) {
        SearchPatternAnalyzer.SearchAnalysis analysis = SearchPatternAnalyzer.analyzeSearchQuery(searchQuery);

        String normalizedQuery = searchQuery.toLowerCase();
        for (String indicator : KNOWLEDGE_INDICATORS) {
            if (normalizedQuery.contains(indicator)) {
                analysis.confidenceScore += 15;
                analysis.optimizationHints.add('Knowledge-specific pattern detected: ' + indicator);
                break;
            }
        }

        return analysis;
    }

    /**
     * @description Performs direct article lookup by ID
     */
    private List<Knowledge__kav> performDirectLookup(Id articleId, String language, Boolean includeDrafts) {
        String statusClause = includeDrafts ? 'PublishStatus IN (\'Online\', \'Draft\')' : 'PublishStatus = \'Online\'';
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
     * @description Performs intelligent SOSL search with pattern optimization
     */
    private List<Knowledge__kav> performIntelligentSearch(
        String searchQuery,
        String language,
        Boolean includeDrafts,
        Integer maxResults,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis
    ) {
        String fieldsToSelect = 'Id, Title, ArticleNumber, Summary, UrlName, LastModifiedDate, CreatedDate, PublishStatus, Language';
        String statusClause = includeDrafts ? 'PublishStatus IN (\'Online\', \'Draft\')' : 'PublishStatus = \'Online\'';

        String soslScope = patternAnalysis != null ? patternAnalysis.recommendedSOSLScope : 'ALL FIELDS';
        String soslQuery =
            'FIND :searchQuery IN ' +
            soslScope +
            ' RETURNING Knowledge__kav(' +
            fieldsToSelect +
            ' WHERE ' +
            statusClause +
            ' AND Language = :language' +
            ' ORDER BY LastModifiedDate DESC LIMIT ' +
            maxResults +
            ')';

        try {
            List<List<SObject>> searchResults = Search.query(soslQuery);
            return (List<Knowledge__kav>) searchResults[0];
        } catch (SearchException se) {
            if (!soslScope.equals('ALL FIELDS')) {
                String fallbackQuery = soslQuery.replace('IN ' + soslScope, 'IN ALL FIELDS');
                List<List<SObject>> fallbackResults = Search.query(fallbackQuery);
                return (List<Knowledge__kav>) fallbackResults[0];
            }
            throw new QueryException('Knowledge SOSL search failed: ' + se.getMessage());
        }
    }

    /**
     * @description Scores and ranks Knowledge search results
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

        scoredResults.sort();
        return scoredResults;
    }

    /**
     * @description Calculates relevance score for Knowledge articles
     */
    private Integer calculateKnowledgeRelevanceScore(Knowledge__kav article, String searchQuery, Integer soslPosition) {
        Integer score = 1000 - (soslPosition * 10);

        if (String.isNotBlank(searchQuery)) {
            String queryLower = searchQuery.toLowerCase();

            if (article.Title != null && article.Title.toLowerCase().contains(queryLower)) {
                score += 200;
                if (article.Title.toLowerCase().equals(queryLower)) {
                    score += 100;
                }
            }

            if (article.Summary != null && article.Summary.toLowerCase().contains(queryLower)) {
                score += 100;
            }

            if (article.ArticleNumber != null && article.ArticleNumber.toLowerCase().contains(queryLower)) {
                score += 150;
            }
        }

        if (article.LastModifiedDate != null && article.LastModifiedDate > DateTime.now().addDays(-30)) {
            score += 50;
        }

        return score;
    }

    /**
     * @description Processes Knowledge search results and builds response
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
     * @description Determines if there's a definitive best match
     */
    private Boolean hasDefinitiveBestMatch(List<ScoredKnowledgeResult> scoredResults) {
        if (scoredResults.size() < 2)
            return true;

        Integer topScore = scoredResults[0].score;
        Integer secondScore = scoredResults[1].score;

        return (topScore - secondScore) > 100;
    }

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
     * @description Scored Knowledge result for ranking
     */
    private class ScoredKnowledgeResult implements Comparable {
        public Knowledge__kav article;
        public Integer score;

        public ScoredKnowledgeResult(Knowledge__kav article, Integer score) {
            this.article = article;
            this.score = score;
        }

        public Integer compareTo(Object other) {
            return ((ScoredKnowledgeResult) other).score - this.score;
        }
    }
}
