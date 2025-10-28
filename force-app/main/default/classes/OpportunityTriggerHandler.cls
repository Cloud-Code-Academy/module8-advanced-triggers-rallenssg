public with sharing class OpportunityTriggerHandler extends TriggerHandler {
    public override void beforeInsert() {
        OpportunityHelper.setDefaultType((List<Opportunity>) Trigger.new);
    }

    public override void beforeDelete() {
       OpportunityHelper.preventDeleteOnClosedOpps((List<Opportunity>) Trigger.old);
    }

    public override void afterInsert() {
        OpportunityHelper.createFollowUpTasks((List<Opportunity>) Trigger.new);
    }

    public override void beforeUpdate() {
        OpportunityHelper.assignPrimaryContactFromCEO((List<Opportunity>) Trigger.new);
        OpportunityHelper.validateAmountAndAppendStageHistory(
            (List<Opportunity>) Trigger.new,
            (Map<Id, Opportunity>) Trigger.oldMap
        );
    }

    public override void afterDelete() {
        OpportunityHelper.notifyOwnersOpportunityDeleted((List<Opportunity>) Trigger.old);
    }

    public override void afterUndelete() {
        OpportunityHelper.assignPrimaryContactAfterUndelete((List<Opportunity>) Trigger.new);
    }
}
