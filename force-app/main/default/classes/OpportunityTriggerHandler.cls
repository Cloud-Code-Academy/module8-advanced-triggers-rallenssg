public with sharing class OpportunityTriggerHandler extends TriggerHandler {
    public override void beforeInsert() {
        for (Opportunity opp : Trigger.new) {
            if (opp.Type == null){
                opp.Type = 'New Customer';
            }
        }
    }

    public override void beforeDelete() {
        for (Opportunity oldOpp : Trigger.old) {
            if (oldOpp.IsClosed) {
                oldOpp.addError('Cannot delete closed opportunity');
            }
        }
    }

    public override void afterInsert() {
        List<Task> tasks = new List<Task>();
        for (Opportunity opp : Trigger.new) {
            tasks.add(
                new Task(
                    Subject = 'Call Primary Contact',
                    WhatId = opp.Id,
                    WhoId = opp.Primary_Contact__c,
                    OwnerId = opp.OwnerId,
                    ActivityDate = Date.today().addDays(3)
                )
            );
        }

        insert tasks;
    }

    public override void afterUpdate() {
        
    }
}