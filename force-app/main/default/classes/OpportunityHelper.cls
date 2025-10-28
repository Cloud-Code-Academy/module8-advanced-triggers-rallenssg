/**
 * Class: OpportunityHelper
 * Description:
 *   Centralized, bulkified helper methods for Opportunity-trigger logic.
 *   Designed for use from trigger handlers across contexts (before/after insert, update, delete, undelete).
 *
 * Key design:
 * - Bulk-safe: All methods accept Lists and use set/map aggregation and batched DML/SOQL.
 * - Governor-aware: Single SOQL per object where possible; minimal per-record processing.
 * - Trigger-ready: Each method documents the intended trigger context(s).
 *
 * Usage:
 *   Called from OpportunityTriggerHandler to keep triggers thin and logic reusable/testable.
 *
 * Notes:
 * - Methods that perform DML are intended for after-contexts unless otherwise specified.
 * - Methods that call addError must be invoked in before-contexts of the relevant operation.
 */
public with sharing class OpportunityHelper {
    /**
     * Sends a single email per owner for each deleted Opportunity.
     *
     * Intended trigger context: after delete
     *
     * Behavior:
     * - Gathers unique owner Ids from the provided Opportunities.
     * - Queries Users and sends plain-text email notifications to owners that have an Email.
     * - Uses Messaging.sendEmail in bulk and catches any exception to avoid trigger failure.
     *
     * @param opps List<Opportunity> - the Opportunities being deleted (from Trigger.old).
     *            Null or empty input is safely ignored.
     */
    public static void notifyOwnersOpportunityDeleted(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) { return; }
        Set<Id> ownerIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.OwnerId != null) { ownerIds.add(opp.OwnerId); }
        }
        if (ownerIds.isEmpty()) { return; }

        Map<Id, User> owners = new Map<Id, User>([
            SELECT Id, Email
            FROM User
            WHERE Id IN :ownerIds
        ]);

        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        for (Opportunity opp : opps) {
            User owner = owners.get(opp.OwnerId);
            if (owner == null || String.isBlank(owner.Email)) { continue; }
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new String[] { owner.Email });
            mail.setSubject('Opportunity Deleted: ' + opp.Name);
            mail.setPlainTextBody('Your Opportunity: ' + opp.Name + ' has been deleted.');
            mails.add(mail);
        }

        if (!mails.isEmpty()) {
            try {
                Messaging.sendEmail(mails);
            } catch (Exception e) {
                System.debug('Exception: ' + e.getMessage());
            }
        }
    }
    
    /**
     * Sets a default Type of 'New Customer' when Type is null.
     *
     * Intended trigger context: before insert, before update
     *
     * @param opps List<Opportunity> - Opportunities to default. Null or empty input is safely ignored.
     * Side effects:
     * - Mutates in-memory records only; no DML is performed.
     */
    public static void setDefaultType(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) { return; }
        for (Opportunity opp : opps) {
            if (opp.Type == null) {
                opp.Type = 'New Customer';
            }
        }
    }
    
    /**
     * Prevents deletion of closed Opportunities. Additionally disallows deletion for
     * Opportunities in 'Closed Won' stage whose Account Industry is 'Banking'.
     *
     * Intended trigger context: before delete
     *
     * Behavior:
     * - Performs a single SOQL query for Accounts related to the provided Opportunities.
     * - Uses addError to block deletion when conditions are met.
     *
     * @param opps List<Opportunity> - Opportunities being deleted (from Trigger.old).
     *            Null or empty input is safely ignored.
     */
    public static void preventDeleteOnClosedOpps(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) { return; }
        Map<Id, Account> accounts = new Map<Id, Account>([
            SELECT Id, Industry
            FROM Account
            WHERE Id IN (SELECT AccountId FROM Opportunity WHERE Id IN :opps)
        ]);
        for (Opportunity opp : opps) {
            if (opp.StageName == 'Closed Won' && accounts.get(opp.AccountId).Industry == 'Banking') {
                opp.addError('Cannot delete closed opportunity');
            } else if (opp.IsClosed) {
                opp.addError('Cannot delete closed opportunity');
            }
        }
    }

    /**
     * Creates follow-up Tasks for each Opportunity, due 3 days from today.
     *
     * Intended trigger context: after insert
     *
     * Behavior:
     * - Builds Task records referencing the Opportunity (WhatId) and its Primary Contact (WhoId).
     * - Performs a single bulk DML insert for Tasks.
     *
     * @param opps List<Opportunity> - Newly created Opportunities. Null or empty input is safely ignored.
     */
    public static void createFollowUpTasks(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) return;
        List<Task> tasks = new List<Task>();
        for (Opportunity opp : opps) {
            tasks.add(new Task(
                Subject = 'Call Primary Contact',
                WhatId = opp.Id,
                WhoId = opp.Primary_Contact__c,
                OwnerId = opp.OwnerId,
                ActivityDate = Date.today().addDays(3)
            ));
        }
        if (!tasks.isEmpty()) {
            insert tasks;
        }
    }

    /**
     * Sets Primary_Contact__c from the Account's CEO contact if the field is blank.
     * If multiple CEO contacts exist for an Account, the first (by FirstName ASC) is used.
     *
     * Intended trigger context: before insert, before update
     *
     * Behavior:
     * - Queries CEO Contacts for related Accounts and maps one contact per Account.
     * - Mutates in-memory Opportunity records; no DML is performed.
     *
     * @param opps List<Opportunity> - Opportunities to backfill. Null or empty input is safely ignored.
     */
    public static void assignPrimaryContactFromCEO(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) { return; }
        Set<Id> accountIds = new Set<Id>();
        for (Opportunity opp : opps) {
            if (opp.AccountId != null) { accountIds.add(opp.AccountId); }
        }
        if (accountIds.isEmpty()) { return; }

        Map<Id, Contact> accountIdToContact = new Map<Id, Contact>();
        for (Contact cont : [
            SELECT Id, FirstName, AccountId
            FROM Contact
            WHERE AccountId IN :accountIds AND Title = 'CEO'
            ORDER BY FirstName ASC
        ]) {
            if (!accountIdToContact.containsKey(cont.AccountId)) {
                accountIdToContact.put(cont.AccountId, cont);
            }
        }

        for (Opportunity opp : opps) {
            if (opp.Primary_Contact__c == null && accountIdToContact.containsKey(opp.AccountId)) {
                opp.Primary_Contact__c = accountIdToContact.get(opp.AccountId).Id;
            }
        }
    }

    /**
     * Validates Amount minimum and appends stage-change history to Description.
     *
     * Intended trigger context: before update
     *
     * Behavior:
     * - Adds an error if Amount is less than 5000.
     * - When StageName changes compared to oldMap, appends a timestamped "Stage Change" note to Description.
     *
     * @param newOpps List<Opportunity> - Trigger.new records to validate. Null or empty input is safely ignored.
     * @param oldMap  Map<Id, Opportunity> - Trigger.oldMap for detecting StageName changes. May be null.
     */
    public static void validateAmountAndAppendStageHistory(List<Opportunity> newOpps, Map<Id, Opportunity> oldMap) {
        if (newOpps == null || newOpps.isEmpty()) { return; }
        for (Opportunity opp : newOpps) {
            if (opp.Amount < 5000) {
                opp.addError('Opportunity amount must be greater than 5000');
            }
            Opportunity oldOpp = oldMap != null ? oldMap.get(opp.Id) : null;
            if (oldOpp != null && oldOpp.StageName != opp.StageName) {
                opp.Description = (String.isBlank(opp.Description)) ?
                    'Stage Change:' + opp.StageName + ':' + DateTime.now().format() :
                    opp.Description + '\n Stage Change:' + opp.StageName + ':' + DateTime.now().format();
            }
        }
    }

    /**
     * After undelete, assigns Primary_Contact__c to the Account's 'VP Sales' contact
     * when Primary_Contact__c is currently blank.
     *
     * Intended trigger context: after undelete
     *
     * Behavior:
     * - Deep clones input with preserveId to allow safe DML updates.
     * - Queries a 'VP Sales' Contact per Account and updates only Opportunities needing a value.
     * - Performs a single bulk update.
     *
     * @param opps List<Opportunity> - Undeleted Opportunities (from Trigger.new).
     *            Null or empty input is safely ignored.
     */
    public static void assignPrimaryContactAfterUndelete(List<Opportunity> opps) {
        if (opps == null || opps.isEmpty()) { return; }

        Map<Id, Id> consByAcctId = new Map<Id, Id>();
        List<Opportunity> newOpps = opps.deepClone(true, false, true);

        for (Opportunity opp : newOpps) {
            if (opp.Primary_Contact__c == null && opp.AccountId != null) {
                consByAcctId.put(opp.AccountId, null);
            }
        }
        if (consByAcctId.isEmpty()) { return; }

        for (Contact con : [
            SELECT Id, AccountId
            FROM Contact
            WHERE AccountId IN :consByAcctId.keySet()
            AND Title = 'VP Sales'
        ]) {
            consByAcctId.put(con.AccountId, con.Id);
        }

        List<Opportunity> oppsToUpdate = new List<Opportunity>();
        for (Opportunity opp : newOpps) {
            if (consByAcctId.containsKey(opp.AccountId) && opp.Primary_Contact__c == null) {
                opp.Primary_Contact__c = consByAcctId.get(opp.AccountId);
                oppsToUpdate.add(opp);
            }
        }
        if (!oppsToUpdate.isEmpty()) {
            update oppsToUpdate;
        }
    }
}
