public static void enableKnowledgeUser() {
    User u = [SELECT Id, UserPermissionsKnowledgeUser FROM User WHERE Id = :UserInfo.getUserId()];
    if (!u.UserPermissionsKnowledgeUser) {
        u.UserPermissionsKnowledgeUser = true;
        update u;
    }
}