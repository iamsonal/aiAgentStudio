/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ResultScoringService: Centralized service for scoring and ranking search results with intelligent algorithms.
 *
 * This service encapsulates all scoring logic for search results, providing consistent, pattern-aware relevance
 * scoring and ranking. It implements multiple scoring strategies including pattern-based scoring, traditional
 * field matching, and confidence-weighted scoring to ensure optimal result ordering for AI agent workflows.
 *
 * Key Responsibilities:
 *   - Scores search results using pattern-aware algorithms
 *   - Ranks results based on calculated scores
 *   - Implements multiple scoring strategies for different search patterns
 *   - Provides extensible framework for adding new scoring algorithms
 */
public class ResultScoringService {
    private static final Integer NAME_FIELD_MATCH_SCORE = 100;
    private static final Integer KEY_FIELD_MATCH_SCORE = 50;

    public class ScoredResult implements Comparable {
        public SObject record;
        public Integer score;
        public String displayLabel;

        public ScoredResult(SObject record, Integer score, String displayLabel) {
            this.record = record;
            this.score = score;
            this.displayLabel = displayLabel;
        }

        public Integer compareTo(Object other) {
            ScoredResult otherResult = (ScoredResult) other;
            return otherResult.score - this.score; // Descending order
        }
    }

    public class ScoringInfo {
        public String primaryNameField;
        public Set<String> keyIdentifierFields;

        public ScoringInfo(String nameField, Set<String> keyFields) {
            this.primaryNameField = nameField;
            this.keyIdentifierFields = keyFields;
        }
    }

    /**
     * @description
     * Scores and ranks search results using pattern-aware and traditional scoring algorithms.
     *
     * @param searchResults List of SOSL search results grouped by SObject type
     * @param searchQuery Original search query for scoring context
     * @param patternAnalysis Pattern analysis for pattern-aware scoring
     * @param scoringConfig Configuration mapping for scoring fields per SObject type
     * @return List of scored and ranked results in descending order of relevance
     */
    public static List<ScoredResult> scoreAndRankResults(
        List<List<SObject>> searchResults,
        String searchQuery,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis,
        Map<String, ScoringInfo> scoringConfig
    ) {
        List<ScoredResult> scoredList = new List<ScoredResult>();
        Integer initialScore = 50; // Base score for SOSL ordering

        for (List<SObject> sObjectList : searchResults) {
            for (SObject sObj : sObjectList) {
                Integer score = initialScore--;
                String sObjNameLower = sObj.getSObjectType().getDescribe().getName().toLowerCase();
                ScoringInfo scoringInfo = scoringConfig.get(sObjNameLower);

                if (scoringInfo != null) {
                    score += calculatePatternAwareScore(sObj, searchQuery, patternAnalysis, scoringInfo);
                    score += calculateTraditionalScore(sObj, searchQuery, scoringInfo);
                }

                String displayLabel = buildDisplayLabel(sObj, scoringInfo);
                scoredList.add(new ScoredResult(sObj, score, displayLabel));
            }
        }

        scoredList.sort();
        System.debug(
            LoggingLevel.DEBUG,
            '[ResultScoringService] Scored ' + scoredList.size() + ' results using pattern: ' + patternAnalysis.primaryPattern
        );
        return scoredList;
    }

    private static Integer calculatePatternAwareScore(
        SObject sObj,
        String searchQuery,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis,
        ScoringInfo scoringInfo
    ) {
        Integer patternScore = 0;

        switch on patternAnalysis.primaryPattern {
            when EMAIL_SEARCH {
                patternScore += scoreEmailPattern(sObj, patternAnalysis);
            }
            when PHONE_SEARCH {
                patternScore += scorePhonePattern(sObj, patternAnalysis);
            }
            when PERSON_NAME {
                patternScore += scorePersonNamePattern(sObj, patternAnalysis);
            }
            when IDENTIFIER_SEARCH {
                patternScore += scoreIdentifierPattern(sObj, patternAnalysis, scoringInfo);
            }
        }

        return (Integer) (patternScore * (patternAnalysis.confidenceScore / 100.0));
    }

    private static Integer calculateTraditionalScore(SObject sObj, String searchQuery, ScoringInfo scoringInfo) {
        Integer score = 0;

        Object nameValue = sObj.get(scoringInfo.primaryNameField);
        if (nameValue != null && String.valueOf(nameValue).toLowerCase().contains(searchQuery.toLowerCase())) {
            score += NAME_FIELD_MATCH_SCORE;
        }

        for (String keyField : scoringInfo.keyIdentifierFields) {
            Object keyValue = sObj.get(keyField);
            if (keyValue != null && String.valueOf(keyValue).toLowerCase().contains(searchQuery.toLowerCase())) {
                score += KEY_FIELD_MATCH_SCORE;
            }
        }

        return score;
    }

    private static Integer scoreEmailPattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        String extractedEmail = (String) patternAnalysis.patternMetadata?.get('extractedEmail');
        if (String.isBlank(extractedEmail))
            return 0;

        for (String field : new List<String>{ 'Email', 'PersonEmail', 'WorkEmail' }) {
            if (sObj.isSet(field)) {
                Object fieldValue = sObj.get(field);
                if (fieldValue != null && String.valueOf(fieldValue).equalsIgnoreCase(extractedEmail)) {
                    return 150;
                }
            }
        }
        return 0;
    }

    private static Integer scorePhonePattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        String extractedPhone = (String) patternAnalysis.patternMetadata?.get('extractedPhone');
        if (String.isBlank(extractedPhone))
            return 0;

        for (String field : new List<String>{ 'Phone', 'MobilePhone', 'HomePhone', 'WorkPhone' }) {
            if (sObj.isSet(field)) {
                Object fieldValue = sObj.get(field);
                if (fieldValue != null && normalizePhoneNumber(String.valueOf(fieldValue)).equals(normalizePhoneNumber(extractedPhone))) {
                    return 140;
                }
            }
        }
        return 0;
    }

    private static Integer scorePersonNamePattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        List<String> nameParts = (List<String>) patternAnalysis.patternMetadata?.get('nameParts');
        if (nameParts == null || nameParts.size() < 2)
            return 0;

        Map<String, Object> populatedFields = sObj.getPopulatedFieldsAsMap();
        String firstName = populatedFields.containsKey('FirstName') && populatedFields.get('FirstName') != null
            ? String.valueOf(populatedFields.get('FirstName')).toLowerCase()
            : null;
        String lastName = populatedFields.containsKey('LastName') && populatedFields.get('LastName') != null
            ? String.valueOf(populatedFields.get('LastName')).toLowerCase()
            : null;

        if (firstName != null || lastName != null) {
            Boolean firstNameMatch = firstName != null && nameParts.contains(firstName);
            Boolean lastNameMatch = lastName != null && nameParts.contains(lastName);

            if (firstNameMatch && lastNameMatch)
                return 120;
            if (firstNameMatch || lastNameMatch)
                return 60;
        }
        return 0;
    }

    private static Integer scoreIdentifierPattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis, ScoringInfo scoringInfo) {
        String extractedId = (String) patternAnalysis.patternMetadata?.get('extractedIdentifier');
        if (String.isBlank(extractedId))
            return 0;

        for (String keyField : scoringInfo.keyIdentifierFields) {
            if (sObj.isSet(keyField)) {
                Object fieldValue = sObj.get(keyField);
                if (fieldValue != null && String.valueOf(fieldValue).equalsIgnoreCase(extractedId)) {
                    return 160;
                }
            }
        }
        return 0;
    }

    private static String normalizePhoneNumber(String phone) {
        return String.isBlank(phone) ? '' : phone.replaceAll('[^0-9]', '');
    }

    private static String buildDisplayLabel(SObject record, ScoringInfo scoringInfo) {
        if (scoringInfo != null && String.isNotBlank(scoringInfo.primaryNameField)) {
            Object nameValue = record.get(scoringInfo.primaryNameField);
            if (nameValue != null) {
                return String.valueOf(nameValue);
            }
        }
        return record.getSObjectType().getDescribe().getName() + ' (' + record.Id + ')';
    }
}
