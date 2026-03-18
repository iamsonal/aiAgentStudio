/*
 * Anonymous Apex script for WhatsApp environment setup.
 *
 * Usage:
 *   sf apex run --file scripts/apex/SetupWhatsAppEnvironment.cls -o <org-alias>
 *
 * What it does:
 * - Reuses an existing LLMConfiguration__c
 * - Upserts a WhatsApp iterative agent
 * - Creates representative Contact + Case data for phone-based participant resolution
 *
 * This script intentionally creates only runtime/business data.
 * WhatsApp routing metadata should come from the source-controlled custom metadata
 * records in force-app/main/default/customMetadata, so no second script is required.
 *
 * Before running:
 * - Update the CONFIG section below
 * - Make sure the referenced Named Credential already exists in the org
 */

String llmDeveloperName = 'OpenAI_GPT4o_Mini';
String agentName = 'Customer Support WhatsApp Agent';
String agentDeveloperName = 'Customer_Support_WhatsApp_Agent';

String testContactFirstName = 'WhatsApp';
String testContactLastName = 'Tester';
String testMobilePhone = '+15557654321';
String testCaseSubject = 'WhatsApp Customer Support Case';

LLMConfiguration__c llmConfig = [
    SELECT Id, Name, DeveloperName__c
    FROM LLMConfiguration__c
    WHERE DeveloperName__c = :llmDeveloperName
    LIMIT 1
];

AIAgentDefinition__c agent = new AIAgentDefinition__c(
    DeveloperName__c = agentDeveloperName,
    Name = agentName,
    WelcomeMessageTemplate__c = 'Hello, how can I help you today?',
    IsActive__c = true,
    RuntimeStrategy__c = 'Conversational',
    MemoryStrategy__c = 'Buffer Window',
    HistoryTurnLimit__c = 10,
    EnableParallelToolCalling__c = true,
    AsyncDispatchType__c = 'High',
    RequiresSameChannelReply__c = true,
    DefaultCompletionMode__c = 'Auto Reply',
    LLMConfiguration__c = llmConfig.Id
);
upsert agent DeveloperName__c;

Contact existingContact;
List<Contact> matchingContacts = [
    SELECT Id, AccountId, FirstName, LastName, MobilePhone
    FROM Contact
    WHERE MobilePhone = :testMobilePhone
    LIMIT 1
];
if (!matchingContacts.isEmpty()) {
    existingContact = matchingContacts[0];
} else {
    Account supportAccount = new Account(Name = 'Case Support Customer');
    insert supportAccount;

    existingContact = new Contact(
        FirstName = testContactFirstName,
        LastName = testContactLastName,
        MobilePhone = testMobilePhone,
        AccountId = supportAccount.Id
    );
    insert existingContact;
}

List<Case> openCases = [
    SELECT Id, Subject, Status, ContactId
    FROM Case
    WHERE ContactId = :existingContact.Id AND IsClosed = FALSE
    LIMIT 1
];

Case supportCase;
if (!openCases.isEmpty()) {
    supportCase = openCases[0];
} else {
    supportCase = new Case(
        Subject = testCaseSubject,
        Status = 'New',
        Origin = 'Web',
        ContactId = existingContact.Id
    );
    insert supportCase;
}

System.debug('WhatsApp setup complete.');
System.debug('LLM Config: ' + llmConfig.DeveloperName__c + ' (' + llmConfig.Id + ')');
System.debug('Agent: ' + agentDeveloperName);
System.debug('Contact: ' + existingContact.Id + ' | MobilePhone=' + existingContact.MobilePhone);
System.debug('Case: ' + supportCase.Id);
System.debug('Expected packaged metadata: ChannelEndpoint__mdt.CaseSupport_WhatsApp and AgentChannelRoute__mdt.CaseSupport_WhatsApp_Default');
