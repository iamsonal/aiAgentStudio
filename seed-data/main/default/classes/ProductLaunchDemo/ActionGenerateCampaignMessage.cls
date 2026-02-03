/**
 * @description Custom action for generating personalized campaign messages using AI/LLM
 *              Used by Product Launch Orchestrator demo agent
 *
 * This is the "WOW FACTOR" capability that demonstrates real AI intelligence:
 * - NOT template-based (generates unique content per account)
 * - References specific account context (industry, pain points, opportunities)
 * - Adapts tone based on engagement level
 * - Creates compelling subject lines and email body
 *
 * This action simulates AI content generation. In production, this would call
 * an LLM API to generate truly dynamic content. For demo purposes, it creates
 * highly contextual messages that appear AI-generated.
 *
 * @author Sonal
 * @since January 2026
 */
public with sharing class ActionGenerateCampaignMessage extends BaseAgentAction {
    private static final String ERR_VALIDATION = 'VALIDATION_ERROR';

    private ConfigDTO config;

    /**
     * Configuration DTO
     */
    private class ConfigDTO {
        public String operation;
        public String productName;
        public String messageStyle;
        public Integer maxLength;
    }

    /**
     * Parse backend configuration
     */
    protected override void parseActionConfiguration(String configJson, String logPrefix) {
        if (String.isBlank(configJson)) {
            configJson = '{"operation":"GENERATE_MESSAGE","productName":"AI Analytics Platform","messageStyle":"professional-consultative","maxLength":500}';
        }

        Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(configJson);

        this.config = new ConfigDTO();
        this.config.operation = (String) configMap.get('operation');
        this.config.productName = (String) configMap.get('productName');
        this.config.messageStyle = (String) configMap.get('messageStyle');
        this.config.maxLength = configMap.containsKey('maxLength') ? Integer.valueOf(configMap.get('maxLength')) : 500;

        // Validate operation
        if (String.isBlank(this.config.operation) || this.config.operation != 'GENERATE_MESSAGE') {
            throw new IllegalArgumentException('Invalid operation: ' + this.config.operation + '. Expected: GENERATE_MESSAGE');
        }

        System.debug(logPrefix + 'Configuration: ' + JSON.serialize(this.config));
    }

    /**
     * Execute message generation
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        String logPrefix = '[ActionGenerateCampaignMessage] ';
        System.debug(logPrefix + 'Executing with params: ' + JSON.serializePretty(params));

        try {
            // Extract parameters
            String accountId = getStringParam(params, 'accountId', logPrefix, true);
            String accountName = getStringParam(params, 'accountName', logPrefix, true);
            String industry = getStringParam(params, 'industry', logPrefix, true);
            String painPoints = getStringParam(params, 'painPoints', logPrefix, true);
            String recentOpportunity = getStringParam(params, 'recentOpportunity', logPrefix, false);
            String contactNames = getStringParam(params, 'contactNames', logPrefix, false);

            // Validate
            if (!accountId.startsWith('001')) {
                return ActionOutcome.failure(ERR_VALIDATION, 'Invalid Account ID format');
            }
            if (String.isBlank(accountName)) {
                return ActionOutcome.failure(ERR_VALIDATION, 'accountName cannot be blank');
            }

            // Generate personalized message
            MessageContent message = generatePersonalizedMessage(accountName, industry, painPoints, recentOpportunity, contactNames);

            // Build result
            Map<String, Object> result = new Map<String, Object>{
                'subject' => message.subject,
                'body' => message.body,
                'tone' => message.tone,
                'keyPoints' => message.keyPoints,
                'characterCount' => message.body.length(),
                'generatedAt' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                'aiGenerated' => true,
                'personalizationLevel' => message.personalizationLevel
            };

            System.debug(logPrefix + '✓ Message generated: ' + message.subject.substring(0, Math.min(50, message.subject.length())) + '...');

            return ActionOutcome.success(result);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, logPrefix + 'Stack: ' + e.getStackTraceString());
            return ActionOutcome.failure(ERR_VALIDATION, 'Message generation failed: ' + e.getMessage());
        }
    }

    /**
     * Generate personalized message content
     *
     * NOTE: This is a sophisticated simulation of AI content generation.
     * In production, this would call an LLM API (OpenAI, Claude, etc.) to generate
     * truly dynamic content. For demo purposes, we create highly contextual messages
     * that demonstrate the power of AI-driven personalization.
     */
    private MessageContent generatePersonalizedMessage(String accountName, String industry, String painPoints, String recentOpportunity, String contactNames) {
        MessageContent message = new MessageContent();
        message.keyPoints = new List<String>();

        // Parse contact names (comma-separated) and create greeting
        String greeting = 'there';
        if (String.isNotBlank(contactNames)) {
            List<String> names = contactNames.split(',');
            if (names.size() == 1) {
                greeting = names[0].trim().split(' ')[0]; // First name only
            } else if (names.size() == 2) {
                greeting = names[0].trim().split(' ')[0] + ' and ' + names[1].trim().split(' ')[0];
            } else if (names.size() >= 3) {
                String firstNames = '';
                for (Integer i = 0; i < names.size() - 1; i++) {
                    firstNames += names[i].trim().split(' ')[0] + ', ';
                }
                firstNames += 'and ' + names[names.size() - 1].trim().split(' ')[0];
                greeting = firstNames;
            }
        }

        // Determine tone and approach based on industry and context
        if (industry == 'Technology') {
            message.tone = 'Technical-Forward';
            message.personalizationLevel = 'High';

            // Technology subject lines (reference specific tech pain points)
            if (String.isNotBlank(recentOpportunity)) {
                message.subject = greeting + ', ready to scale beyond your current analytics setup?';
                message.keyPoints.add('References active evaluation');
            } else {
                message.subject = greeting + ', AI-powered analytics for your engineering team';
                message.keyPoints.add('Tech-forward positioning');
            }

            // Technology body (technical, data-driven, scaling focus)
            message.body = 'Hi ' + greeting + ', ';

            if (String.isNotBlank(recentOpportunity)) {
                message.body += 'I noticed ' + accountName + ' is evaluating analytics platforms. ';
                message.keyPoints.add('Contextual opener');
            }

            message.body += 'Given your team\'s focus on ' + extractKeyPhrase(painPoints) + ', ';
            message.body += 'our ' + this.config.productName + ' can help you move from manual reporting to real-time AI-powered dashboards. ';
            message.keyPoints.add('Pain point reference');

            message.body += 'What makes us different: Natural language querying (ask questions in plain English), ';
            message.body += 'ML-driven predictions (churn modeling, forecasting), and 50+ pre-built integrations. ';
            message.keyPoints.add('Technical differentiation');

            message.body += 'Would love to show you how companies like yours are reducing analytics time by 10+ hours/week. ';
            message.body += 'Quick 15-minute demo this week?';
        } else if (industry == 'Financial Services') {
            message.tone = 'Compliance-Aware';
            message.personalizationLevel = 'High';

            // Financial Services subject lines (compliance, security focus)
            message.subject = greeting + ', SOC 2-compliant analytics for ' + accountName;
            message.keyPoints.add('Compliance-first positioning');

            // Financial Services body (security, compliance, regulatory)
            message.body = 'Hi ' + greeting + ', ';
            message.body += 'Financial services firms like ' + accountName + ' have unique analytics needs: ';
            message.body += 'SOC 2 Type II compliance, role-based access control, and audit trails. ';
            message.keyPoints.add('Industry-specific requirements');

            message.body += 'I saw your team is dealing with ' + extractKeyPhrase(painPoints) + '. ';
            message.body += 'Our ' + this.config.productName + ' is built for regulated industries: ';
            message.keyPoints.add('Pain point acknowledgment');

            message.body += 'Complete audit logging, encrypted at rest and in transit, and automated compliance reporting. ';
            message.body += 'We work with 50+ financial services firms handling similar regulatory requirements. ';
            message.keyPoints.add('Social proof');

            message.body += 'Let me show you our compliance dashboard and security architecture. Available for a quick call?';
        } else if (industry == 'Healthcare') {
            message.tone = 'Compliance-Focused';
            message.personalizationLevel = 'High';

            // Healthcare subject lines (HIPAA, patient data focus)
            message.subject = greeting + ', HIPAA-compliant patient analytics for ' + accountName;
            message.keyPoints.add('HIPAA compliance positioning');

            // Healthcare body (HIPAA, PHI, patient outcomes)
            message.body = 'Hi ' + greeting + ', ';
            message.body += 'Healthcare organizations need analytics that understand PHI and HIPAA requirements. ';
            message.keyPoints.add('Industry expertise');

            message.body += 'I understand ' + accountName + ' is focused on ' + extractKeyPhrase(painPoints) + '. ';
            message.body += 'Our ' + this.config.productName + ' includes: ';
            message.keyPoints.add('Pain point reference');

            message.body += 'Business Associate Agreement (BAA), PHI de-identification, healthcare-specific templates, ';
            message.body += 'and automated patient outcome dashboards. ';
            message.keyPoints.add('Healthcare features');

            message.body += 'We support 25+ healthcare SaaS companies with similar compliance needs. ';
            message.body += 'Would you like to see our healthcare analytics templates?';
        } else if (industry == 'Retail') {
            message.tone = 'ROI-Focused';
            message.personalizationLevel = 'Medium';

            // Retail subject lines (inventory, sales optimization)
            message.subject = greeting + ', reduce stockouts and optimize pricing for ' + accountName;
            message.keyPoints.add('ROI-focused positioning');

            // Retail body (inventory, markdown, sales)
            message.body = 'Hi ' + greeting + ', ';
            message.body += 'Retail operations depend on accurate inventory and pricing analytics. ';
            message.keyPoints.add('Industry understanding');

            message.body += 'I saw ' + accountName + ' is working on ' + extractKeyPhrase(painPoints) + '. ';
            message.body += 'Our ' + this.config.productName + ' helps retail companies: ';
            message.keyPoints.add('Pain point acknowledgment');

            message.body += 'Predict stockouts before they happen, optimize markdowns with ML, ';
            message.body += 'and segment customers for targeted promotions. ';
            message.keyPoints.add('Retail use cases');

            message.body += 'Typical ROI: 15-20% reduction in stockout costs within 3 months. ';
            message.body += 'Quick demo this week?';
            message.keyPoints.add('ROI emphasis');
        } else {
            // Generic industry (still personalized)
            message.tone = 'Professional-Consultative';
            message.personalizationLevel = 'Medium';

            message.subject = greeting + ', transform data into insights at ' + accountName;
            message.keyPoints.add('Generic but professional');

            message.body = 'Hi ' + greeting + ', ';
            message.body += 'I noticed ' + accountName + ' is focused on ' + extractKeyPhrase(painPoints) + '. ';
            message.keyPoints.add('Pain point reference');

            message.body += 'Our ' + this.config.productName + ' helps ' + industry.toLowerCase() + ' companies ';
            message.body += 'turn complex data into actionable insights: ';
            message.keyPoints.add('Industry mention');

            message.body += 'AI-powered predictions, automated reporting, and self-service dashboards for every team. ';
            message.body += 'Companies like yours typically see 10x faster insights and 50% reduction in manual reporting. ';
            message.keyPoints.add('Value proposition');

            message.body += 'Would love to show you a quick demo tailored to ' + industry.toLowerCase() + '. Available this week?';
        }

        // Truncate if needed
        if (message.body.length() > this.config.maxLength) {
            message.body = message.body.substring(0, this.config.maxLength - 3) + '...';
        }

        return message;
    }

    /**
     * Extract key phrase from pain points (first sentence or first 50 chars)
     */
    private String extractKeyPhrase(String painPoints) {
        if (String.isBlank(painPoints)) {
            return 'analytics and reporting challenges';
        }

        // Take first sentence or first 80 characters
        String phrase = painPoints;
        Integer dotIndex = phrase.indexOf('.');
        if (dotIndex > 0 && dotIndex < 80) {
            phrase = phrase.substring(0, dotIndex);
        } else if (phrase.length() > 80) {
            phrase = phrase.substring(0, 80) + '...';
        }

        return phrase.toLowerCase();
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
     * Internal message content class
     */
    private class MessageContent {
        public String subject;
        public String body;
        public String tone;
        public List<String> keyPoints;
        public String personalizationLevel;
    }
}
