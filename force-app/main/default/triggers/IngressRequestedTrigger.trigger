trigger IngressRequestedTrigger on IngressRequested__e(after insert) {
    IngressRequestedTriggerHandler.handle(Trigger.New);
}
