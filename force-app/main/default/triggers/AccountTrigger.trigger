trigger AccountTrigger on Account (before insert, after insert) {
    if (Trigger.isBefore && Trigger.isInsert) {
        AccountHelper.setTypeProspect(Trigger.new);
        AccountHelper.addressCopy(Trigger.new);
        AccountHelper.setRating(Trigger.new);
    }
    
    if (Trigger.isAfter && Trigger.isInsert) {
        AccountHelper.defaultContact(Trigger.new);
    }
}