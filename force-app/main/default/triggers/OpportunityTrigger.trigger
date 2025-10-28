trigger OpportunityTrigger on Opportunity (before insert, before update, after update, before delete, after undelete, after insert, after delete) {
    new OpportunityTriggerHandler().run();
}