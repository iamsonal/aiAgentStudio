/**
 * @description Tests deterministic resolution of HITL approval routing metadata.
 */
@IsTest
private class HITLApprovalRouteResolverTest {
    @IsTest
    static void testResolve_PicksHighestPriorityMatch() {
        HITLApprovalRouteResolver.setTestRoutes(
            new List<HITLApprovalRoute__mdt>{
                new HITLApprovalRoute__mdt(
                    DeveloperName = 'LowPriorityRoute',
                    MasterLabel = 'Low Priority Route',
                    ArtifactType__c = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL,
                    ApprovalCategory__c = HITLGatewayService.APPROVAL_CATEGORY_TOOL_APPROVAL,
                    ApprovalProcessDeveloperName__c = 'Tool_Approval',
                    Priority__c = 10,
                    IsActive__c = true
                ),
                new HITLApprovalRoute__mdt(
                    DeveloperName = 'HighPriorityRoute',
                    MasterLabel = 'High Priority Route',
                    ArtifactType__c = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL,
                    ApprovalCategory__c = HITLGatewayService.APPROVAL_CATEGORY_TOOL_APPROVAL,
                    ApprovalProcessDeveloperName__c = 'Tool_Approval',
                    Priority__c = 100,
                    IsActive__c = true
                )
            }
        );

        HITLApprovalRouteResolver.RouteContext context = new HITLApprovalRouteResolver.RouteContext();
        context.artifactType = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL;

        HITLApprovalRouteResolver.ResolvedRoute route = HITLApprovalRouteResolver.resolve(context);

        System.assertEquals('HighPriorityRoute', route.routeDeveloperName, 'Higher-priority routes should win.');
    }

    @IsTest
    static void testResolve_PicksMoreSpecificRouteWhenPriorityMatches() {
        HITLApprovalRouteResolver.setTestRoutes(
            new List<HITLApprovalRoute__mdt>{
                new HITLApprovalRoute__mdt(
                    DeveloperName = 'GenericToolRoute',
                    MasterLabel = 'Generic Tool Route',
                    ArtifactType__c = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL,
                    ApprovalCategory__c = HITLGatewayService.APPROVAL_CATEGORY_TOOL_APPROVAL,
                    ApprovalProcessDeveloperName__c = 'Tool_Approval',
                    Priority__c = 100,
                    IsActive__c = true
                ),
                new HITLApprovalRoute__mdt(
                    DeveloperName = 'EmailToolRoute',
                    MasterLabel = 'Email Tool Route',
                    ArtifactType__c = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL,
                    InteractionChannel__c = RuntimeRegistryService.CHANNEL_EMAIL,
                    ApprovalCategory__c = HITLGatewayService.APPROVAL_CATEGORY_TOOL_APPROVAL,
                    ApprovalProcessDeveloperName__c = 'Tool_Approval',
                    Priority__c = 100,
                    IsActive__c = true
                )
            }
        );

        HITLApprovalRouteResolver.RouteContext context = new HITLApprovalRouteResolver.RouteContext();
        context.artifactType = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL;
        context.interactionChannel = RuntimeRegistryService.CHANNEL_EMAIL;

        HITLApprovalRouteResolver.ResolvedRoute route = HITLApprovalRouteResolver.resolve(context);

        System.assertEquals('EmailToolRoute', route.routeDeveloperName, 'More-specific routes should win when priority matches.');
    }

    @IsTest
    static void testResolve_ThrowsForAmbiguousRoutes() {
        HITLApprovalRouteResolver.setTestRoutes(
            new List<HITLApprovalRoute__mdt>{
                new HITLApprovalRoute__mdt(
                    DeveloperName = 'RouteOne',
                    MasterLabel = 'Route One',
                    ArtifactType__c = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL,
                    ApprovalCategory__c = HITLGatewayService.APPROVAL_CATEGORY_TOOL_APPROVAL,
                    ApprovalProcessDeveloperName__c = 'Tool_Approval',
                    Priority__c = 100,
                    IsActive__c = true
                ),
                new HITLApprovalRoute__mdt(
                    DeveloperName = 'RouteTwo',
                    MasterLabel = 'Route Two',
                    ArtifactType__c = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL,
                    ApprovalCategory__c = HITLGatewayService.APPROVAL_CATEGORY_TOOL_APPROVAL,
                    ApprovalProcessDeveloperName__c = 'Tool_Approval',
                    Priority__c = 100,
                    IsActive__c = true
                )
            }
        );

        HITLApprovalRouteResolver.RouteContext context = new HITLApprovalRouteResolver.RouteContext();
        context.artifactType = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL;

        try {
            HITLApprovalRouteResolver.resolve(context);
            System.assert(false, 'Expected route resolution to fail for ambiguous matches.');
        } catch (HITLApprovalRouteResolver.RouteResolutionException e) {
            System.assert(e.getMessage().contains('Ambiguous'), 'Ambiguous matches should throw a clear configuration error.');
        }
    }
}
