/**
 * @description Apex Context Provider (User Anchored).
 *              Provides a HARDCODED summary of the User's sales pipeline,
 *              simulating behavior driven by JSON configuration.
 *              In a real scenario, this would query Opportunities based on
 *              ownership and criteria derived from the configuration JSON.
 * @implements IAgentContextProvider
 */
public class UserPipelineSummaryProvider implements IAgentContextProvider {

    // Constants for expected JSON configuration keys
    private static final String CONFIG_KEY_TIME_PERIOD_TYPE = 'timePeriodType'; // e.g., "CurrentFQ", "NextNDays"
    private static final String CONFIG_KEY_TIME_PERIOD_VALUE = 'timePeriodValue'; // e.g., 30 (for NextNDays)
    private static final String CONFIG_KEY_HIGH_VALUE_THRESHOLD = 'highValueThreshold'; // e.g., 50000
    private static final String CONFIG_KEY_STALLED_DAYS = 'stalledActivityDays'; // e.g., 14

    /**
     * @description Retrieves user-specific context.
     *              Returns a hardcoded pipeline summary, simulating interpretation of configuration.
     * @param anchorId The Salesforce ID of the anchor User record.
     * @param userId The Salesforce ID of the user initiating the request (same as anchorId here).
     * @param configurationJson JSON String with config like:
     *        {"timePeriodType": "CurrentFQ", "highValueThreshold": 50000, "stalledActivityDays": 14}
     * @return Map containing a List with one Note SObject holding the summary.
     *         Returns an empty map if the anchor is not a User or config parsing fails.
     */
    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        final String logPrefix = '[UserPipelineSummaryProvider User:' + userId + '] ';
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        // --- 1. Validate Anchor is a User ---
        // For User Anchored, anchorId *is* the userId.
        if (anchorId == null || anchorId.getSObjectType() != User.SObjectType) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Anchor ID is null or not a User. Skipping.');
            return results; // Return empty map
        }
        // We can also validate anchorId == userId if desired, though the framework likely ensures this.

        System.debug(LoggingLevel.INFO, logPrefix + 'Generating user pipeline summary context.');

        // --- 2. Parse Configuration (with defaults) ---
        String timePeriodLabel = 'Current Fiscal Quarter'; // Default label
        Decimal highValueThreshold = 50000; // Default threshold
        Integer stalledDays = 14; // Default stall period

        if (String.isNotBlank(configurationJson)) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Parsing Configuration JSON: ' + configurationJson);
            try {
                Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(configurationJson);

                // Safely parse timePeriodType and set label
                if (config.containsKey(CONFIG_KEY_TIME_PERIOD_TYPE) && config.get(CONFIG_KEY_TIME_PERIOD_TYPE) instanceof String) {
                    String type = (String) config.get(CONFIG_KEY_TIME_PERIOD_TYPE);
                    if ('NextNDays'.equalsIgnoreCase(type) && config.containsKey(CONFIG_KEY_TIME_PERIOD_VALUE) && (config.get(CONFIG_KEY_TIME_PERIOD_VALUE) instanceof Integer || config.get(CONFIG_KEY_TIME_PERIOD_VALUE) instanceof Decimal)) {
                        Decimal daysDecimal = (Decimal)config.get(CONFIG_KEY_TIME_PERIOD_VALUE);
                        Integer days = daysDecimal.intValue(); // Convert Decimal/Integer to Integer safely
                        timePeriodLabel = 'Next ' + days + ' Days';
                    } else if ('CurrentFQ'.equalsIgnoreCase(type)) {
                        timePeriodLabel = 'Current Fiscal Quarter';
                    } else if ('CurrentCalendarMonth'.equalsIgnoreCase(type)){
                        timePeriodLabel = 'Current Calendar Month';
                    }
                    // Add more time period logic as needed
                }

                // Safely parse highValueThreshold
                if (config.containsKey(CONFIG_KEY_HIGH_VALUE_THRESHOLD) && (config.get(CONFIG_KEY_HIGH_VALUE_THRESHOLD) instanceof Integer || config.get(CONFIG_KEY_HIGH_VALUE_THRESHOLD) instanceof Decimal)) {
                    Decimal thresholdDecimal = (Decimal)config.get(CONFIG_KEY_HIGH_VALUE_THRESHOLD);
                    highValueThreshold = thresholdDecimal; // Assign parsed decimal value
                }

                // Safely parse stalledDays
                if (config.containsKey(CONFIG_KEY_STALLED_DAYS) && (config.get(CONFIG_KEY_STALLED_DAYS) instanceof Integer || config.get(CONFIG_KEY_STALLED_DAYS) instanceof Decimal)) {
                    Decimal stalledDecimal = (Decimal)config.get(CONFIG_KEY_STALLED_DAYS);
                    stalledDays = stalledDecimal.intValue();
                }

                System.debug(LoggingLevel.INFO, logPrefix + 'Applied Configuration: TimePeriod=' + timePeriodLabel +
                        ', HighValueThreshold=' + highValueThreshold + ', StalledDays=' + stalledDays);

            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Failed to parse ProviderConfiguration JSON. Using defaults. Error: ' + e.getMessage());
                // Continue with default values
            }
        } else {
            System.debug(LoggingLevel.WARN, logPrefix + 'ProviderConfiguration JSON is blank. Using defaults.');
        }


        // --- 3. Prepare Hardcoded Data (Simulating Query Results based on Config) ---
        // In reality, query Opportunity WHERE OwnerId = :userId AND CloseDate fits timePeriodLabel etc.
        String summaryLine = 'Pipeline (' + timePeriodLabel + '): 7 Open Opportunities totaling $315,000.';
        String keyDealsLine = 'Key Deals (> $' + String.valueOf(highValueThreshold.intValue()) + '): Opp Phoenix ($120k, Negotiation), Opp Raptor ($80k, Value Prop).';
        String stalledDealsLine = 'Stalled Deals (No activity > ' + stalledDays + ' days): Opp Sparrow ($25k, Needs Analysis).';
        String sourceLine = '(Pipeline data simulated based on config for user ' + UserInfo.getName() + ')';

        String combinedContent = summaryLine + '\n' + keyDealsLine + '\n' + stalledDealsLine + '\n\n' + sourceLine;


        // --- 4. Package data into a standard SObject (Note) ---
        // Using Note as a container to fit the List<SObject> return type.
        Note pipelineNote = new Note(
                Title = 'My Pipeline Summary (' + timePeriodLabel + ') - Simulated',
                Body = combinedContent
        );

        List<SObject> notesList = new List<SObject>{ pipelineNote };

        // --- 5. Populate Return Map ---
        results.put('My Current Pipeline Summary', notesList); // Descriptive label

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Returning hardcoded context: ' + combinedContent.abbreviate(200));
        return results;
    }
}