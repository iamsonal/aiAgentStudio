/**
 * @description A standard context provider that retrieves key details for a given Contact record.
 *              Implements FLS checks by using a WITH SECURITY_ENFORCED SOQL query.
 */
public class ContactDetailsProvider implements IAgentContextProvider {

    /**
     * @description Retrieves context data for a Contact.
     * @param anchorId The Salesforce ID of the Contact record.
     * @param userId The Salesforce ID of the user initiating the request.
     * @param configurationJson Custom JSON configuration (not used by this simple provider).
     * @return A map where the key is a label and the value is a list containing the found Contact.
     */
    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        // Ensure the anchorId is a Contact ID
        if (anchorId == null || anchorId.getSobjectType() != Contact.SObjectType) {
            System.debug(LoggingLevel.WARN, '[ContactDetailsProvider] Anchor ID is not a valid Contact ID. Skipping.');
            return results;
        }

        try {
            // Securely query for the contact record using the user's permissions.
            // Only include fields that are useful for the LLM as context.
            List<Contact> contacts = [
                    SELECT
                            Id,
                            Name,
                            Title,
                            Email,
                            Phone,
                            MailingStreet,
                            MailingCity,
                            MailingState,
                            MailingPostalCode,
                            MailingCountry,
                            Description,
                            Account.Name
                    FROM Contact
                    WHERE Id = :anchorId
                    WITH SECURITY_ENFORCED
                    LIMIT 1
            ];

            if (!contacts.isEmpty()) {
                // The key 'Contact Details' will be used as the header in the context block.
                results.put('Contact Details', contacts);
                System.debug(LoggingLevel.INFO, '[ContactDetailsProvider] Successfully fetched context for Contact: ' + anchorId);
            }
        } catch (Exception e) {
            // Log any query exceptions (e.g., if the user lacks access to the record or a field)
            System.debug(LoggingLevel.ERROR, '[ContactDetailsProvider] Error fetching contact context for ID ' + anchorId + ': ' + e.getMessage());
            // Return empty map on error to prevent breaking the orchestration flow.
        }

        return results;
    }
}