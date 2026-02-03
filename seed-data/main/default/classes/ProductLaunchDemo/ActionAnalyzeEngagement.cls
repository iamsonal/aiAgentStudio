/**
 * @description Custom action for analyzing account engagement levels
 *              Used by Product Launch Orchestrator demo agent
 *
 * This action analyzes multiple engagement signals:
 * - Opportunity stage and amount (late-stage = hot, early-stage = warm)
 * - Recent case count (pre-sales interest)
 * - Activity count (calls, emails, meetings)
 *
 * Returns engagement level: "Hot", "Warm", or "Cold" with detailed reasoning
 *
 * @author Sonal
 * @since January 2026
 */
public with sharing class ActionAnalyzeEngagement extends BaseAgentAction {
    private static final String ERR_VALIDATION = 'VALIDATION_ERROR';

    private ConfigDTO config;

    /**
     * Configuration DTO
     */
    private class ConfigDTO {
        public String operation;
        public Map<String, Object> hotThreshold;
        public Map<String, Object> warmThreshold;
    }

    /**
     * Parse backend configuration
     */
    protected override void parseActionConfiguration(String configJson, String logPrefix) {
        if (String.isBlank(configJson)) {
            configJson = '{"operation":"ANALYZE_ENGAGEMENT","hotThreshold":{"opportunityStages":["Proposal/Price Quote","Negotiation/Review"],"minActivityCount":5},"warmThreshold":{"opportunityStages":["Qualification","Needs Analysis"],"minActivityCount":2}}';
        }

        Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(configJson);

        this.config = new ConfigDTO();
        this.config.operation = (String) configMap.get('operation');
        this.config.hotThreshold = (Map<String, Object>) configMap.get('hotThreshold');
        this.config.warmThreshold = (Map<String, Object>) configMap.get('warmThreshold');

        System.debug(logPrefix + 'Configuration: ' + JSON.serialize(this.config));
    }

    /**
     * Execute engagement analysis
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        String logPrefix = '[ActionAnalyzeEngagement] ';
        System.debug(logPrefix + 'Executing with params: ' + JSON.serializePretty(params));

        try {
            // Extract parameters
            String accountId = getStringParam(params, 'accountId', logPrefix, true);
            String opportunityStageName = getStringParam(params, 'opportunityStageName', logPrefix, false);
            Decimal opportunityAmount = getDecimalParam(params, 'opportunityAmount', logPrefix, false);
            Integer recentCaseCount = getIntegerParam(params, 'recentCaseCount', logPrefix, false, 0);
            Integer recentActivityCount = getIntegerParam(params, 'recentActivityCount', logPrefix, false, 0);

            // Validate Account ID
            if (!accountId.startsWith('001')) {
                return ActionOutcome.failure(ERR_VALIDATION, 'Invalid Account ID format');
            }

            // Analyze engagement
            EngagementResult engagement = analyzeEngagement(opportunityStageName, opportunityAmount, recentCaseCount, recentActivityCount);

            // Build result
            Map<String, Object> result = new Map<String, Object>{
                'engagementLevel' => engagement.level,
                'engagementScore' => engagement.score,
                'reasoning' => engagement.reasoning,
                'keySignals' => engagement.keySignals,
                'recommendedAction' => engagement.recommendedAction,
                'followUpPriority' => engagement.followUpPriority,
                'followUpDays' => engagement.followUpDays,
                'analyzedAt' => System.now().format('yyyy-MM-dd HH:mm:ss')
            };

            System.debug(logPrefix + '✓ Engagement analyzed: ' + engagement.level + ' (Score: ' + engagement.score + ')');

            return ActionOutcome.success(result);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, logPrefix + 'Stack: ' + e.getStackTraceString());
            return ActionOutcome.failure(ERR_VALIDATION, 'Engagement analysis failed: ' + e.getMessage());
        }
    }

    /**
     * Analyze engagement based on signals
     */
    private EngagementResult analyzeEngagement(String opportunityStageName, Decimal opportunityAmount, Integer caseCount, Integer activityCount) {
        EngagementResult result = new EngagementResult();
        result.keySignals = new List<String>();

        Integer score = 0;

        // Analyze opportunity stage (most important signal)
        if (String.isNotBlank(opportunityStageName)) {
            if (isHotStage(opportunityStageName)) {
                score += 40;
                result.keySignals.add('Late-stage opportunity (' + opportunityStageName + ')');
            } else if (isWarmStage(opportunityStageName)) {
                score += 25;
                result.keySignals.add('Early-stage opportunity (' + opportunityStageName + ')');
            } else {
                score += 10;
                result.keySignals.add('Opportunity exists (' + opportunityStageName + ')');
            }
        }

        // Analyze opportunity amount
        if (opportunityAmount != null && opportunityAmount > 0) {
            if (opportunityAmount >= 200000) {
                score += 20;
                result.keySignals.add('Large opportunity ($' + opportunityAmount.format() + ')');
            } else if (opportunityAmount >= 50000) {
                score += 15;
                result.keySignals.add('Medium opportunity ($' + opportunityAmount.format() + ')');
            } else {
                score += 5;
                result.keySignals.add('Small opportunity ($' + opportunityAmount.format() + ')');
            }
        }

        // Analyze recent cases (engagement signal)
        if (caseCount > 0) {
            if (caseCount >= 3) {
                score += 15;
                result.keySignals.add('High case volume (' + caseCount + ' cases in 90 days)');
            } else {
                score += 10;
                result.keySignals.add('Moderate case volume (' + caseCount + ' cases in 90 days)');
            }
        }

        // Analyze activity count
        if (activityCount >= 5) {
            score += 25;
            result.keySignals.add('High activity (' + activityCount + ' activities in 90 days)');
        } else if (activityCount >= 2) {
            score += 15;
            result.keySignals.add('Moderate activity (' + activityCount + ' activities in 90 days)');
        }

        // Determine engagement level
        result.score = score;

        if (score >= 60) {
            result.level = 'Hot';
            result.followUpPriority = 'High';
            result.followUpDays = 3;
            result.recommendedAction = 'Immediate follow-up with personalized outreach. Executive engagement recommended.';
        } else if (score >= 30) {
            result.level = 'Warm';
            result.followUpPriority = 'Normal';
            result.followUpDays = 7;
            result.recommendedAction = 'Standard follow-up with personalized content. Focus on value proposition.';
        } else {
            result.level = 'Cold';
            result.followUpPriority = 'Low';
            result.followUpDays = 14;
            result.recommendedAction = 'Low priority follow-up. Consider nurture campaign instead of direct outreach.';
        }

        // Build reasoning
        result.reasoning = buildReasoning(result);

        return result;
    }

    /**
     * Check if opportunity stage is "hot"
     */
    private Boolean isHotStage(String stage) {
        List<Object> hotStages = (List<Object>) this.config.hotThreshold.get('opportunityStages');
        return hotStages != null && hotStages.contains(stage);
    }

    /**
     * Check if opportunity stage is "warm"
     */
    private Boolean isWarmStage(String stage) {
        List<Object> warmStages = (List<Object>) this.config.warmThreshold.get('opportunityStages');
        return warmStages != null && warmStages.contains(stage);
    }

    /**
     * Build detailed reasoning text
     */
    private String buildReasoning(EngagementResult result) {
        String reasoning = 'Engagement Level: ' + result.level + ' (Score: ' + result.score + '/100). ';

        if (!result.keySignals.isEmpty()) {
            reasoning += 'Key signals: ';
            for (Integer i = 0; i < result.keySignals.size(); i++) {
                reasoning += result.keySignals[i];
                if (i < result.keySignals.size() - 1) {
                    reasoning += '; ';
                }
            }
            reasoning += '. ';
        }

        reasoning += result.recommendedAction;

        return reasoning;
    }

    /**
     * Helper: Extract string parameter
     */
    private String getStringParam(Map<String, Object> params, String key, String logPrefix, Boolean required) {
        if (!params.containsKey(key) || params.get(key) == null) {
            if (required) {
                throw new IllegalArgumentException('Required parameter missing: ' + key);
            }
            return null;
        }

        Object value = params.get(key);
        return value instanceof String ? (String) value : String.valueOf(value);
    }

    /**
     * Helper: Extract decimal parameter
     */
    private Decimal getDecimalParam(Map<String, Object> params, String key, String logPrefix, Boolean required) {
        if (!params.containsKey(key) || params.get(key) == null) {
            if (required) {
                throw new IllegalArgumentException('Required parameter missing: ' + key);
            }
            return null;
        }

        Object value = params.get(key);
        if (value instanceof Decimal) {
            return (Decimal) value;
        } else if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        } else if (value instanceof Long) {
            return Decimal.valueOf((Long) value);
        } else if (value instanceof String) {
            return Decimal.valueOf((String) value);
        } else {
            throw new IllegalArgumentException('Parameter ' + key + ' must be a number');
        }
    }

    /**
     * Helper: Extract integer parameter with default
     */
    private Integer getIntegerParam(Map<String, Object> params, String key, String logPrefix, Boolean required, Integer defaultValue) {
        if (!params.containsKey(key) || params.get(key) == null) {
            if (required) {
                throw new IllegalArgumentException('Required parameter missing: ' + key);
            }
            return defaultValue;
        }

        Object value = params.get(key);
        if (value instanceof Integer) {
            return (Integer) value;
        } else if (value instanceof Decimal) {
            return ((Decimal) value).intValue();
        } else if (value instanceof Long) {
            return ((Long) value).intValue();
        } else if (value instanceof String) {
            return Integer.valueOf((String) value);
        } else {
            throw new IllegalArgumentException('Parameter ' + key + ' must be an integer');
        }
    }

    /**
     * Internal result class
     */
    private class EngagementResult {
        public String level;
        public Integer score;
        public String reasoning;
        public List<String> keySignals;
        public String recommendedAction;
        public String followUpPriority;
        public Integer followUpDays;
    }
}
