/**
 * Created by sonal on 2025-04-19.
 */

({
    doInit: function (component) {
        component.set('v.helpTextMapping', {
            Name: 'The user-friendly display name for this action definition. This label appears in lookup fields and list views when administrators are configuring agent capabilities. Make it clear and concise (e.g., "Create Case Record", "Get Opportunity Details").'
        });

        component.set('v.defaultValues', {
            IsActive__c: true
        });
    }
});
