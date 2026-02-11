/**
 * @description Test provider for ContextResolverService.
 */
@IsTest
public class ContextResolverTestProvider implements IAgentContextProvider {
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
        Set<Id> accountIds = new Set<Id>();
        if (anchorIds != null) {
            for (Id anchorId : anchorIds) {
                if (anchorId != null && anchorId.getSObjectType() == Account.SObjectType) {
                    accountIds.add(anchorId);
                }
            }
        }

        List<SObject> records = new List<SObject>();
        if (!accountIds.isEmpty()) {
            records.addAll([SELECT Id, Name FROM Account WHERE Id IN :accountIds]);
        }

        if (userId != null) {
            List<User> users = [SELECT Id, Name FROM User WHERE Id = :userId];
            records.addAll(users);
        }

        return new Map<String, List<SObject>>{ 'records' => records };
    }
}
