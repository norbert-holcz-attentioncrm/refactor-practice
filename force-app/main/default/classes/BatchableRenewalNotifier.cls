/**
 * Created by norbe on 2026. 02. 15..
 */

public with sharing class BatchableRenewalNotifier
        implements Database.Batchable<SObject>, Database.Stateful {

    private final List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();

    private final List<Renewal_Notification__c> notificationLogs = new List<Renewal_Notification__c>();
    private final List<Contract__c> contractsToUpdate = new List<Contract__c>();
    private final Set<Id> contractIdsToUpdate = new Set<Id>();
    private Map<Id, String> emailAddressByUserId = new Map<Id, String>();

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
                SELECT Id,
                (
                        SELECT Id, Name, OwnerId, Owner.Email, Account__c, End_Date__c, Annual_Value__c, Account__r.Name
                        FROM Contracts__r
                        WHERE Status__c = 'Active'
                        AND (Last_Renewal_Notification_Date__c = NULL OR Last_Renewal_Notification_Date__c < N_DAYS_AGO:7)
                        AND End_Date__c = NEXT_N_DAYS:30
                ),
                (
                        SELECT Severity__c
                        FROM Support_Tickets__r
                        WHERE Status__c = 'Open'
                        AND CreatedDate = LAST_N_DAYS:60
                )
                FROM Account
        ]);
    }

    public void execute(Database.BatchableContext context, List<Account> accounts) {
        Map<Id, List<Contract__c>> contractsByOwnerId = new Map<Id, List<Contract__c>>();
        List<Contract__c> contracts = new List<Contract__c>();
        Map<Id, List<Support_Ticket__c>> ticketsByAccountId = new Map<Id, List<Support_Ticket__c>>();
        Map<Id, Integer> riskScoreByContractId = new Map<Id, Integer>();

        for (Account account : accounts) {
            if (account.Contracts__r != null) {
                contracts.addAll(account.Contracts__r);
            }

            if (account.Support_Tickets__r == null) {
                continue;
            }
            for (Support_Ticket__c supportTicket : account.Support_Tickets__r) {
                if (ticketsByAccountId.get(account.Id) == null) {
                    ticketsByAccountId.put(account.Id, new List<Support_Ticket__c>());
                }
                ticketsByAccountId.get(account.Id).add(supportTicket);
            }
        }

        for (Contract__c contract : contracts) {
            if (contractsByOwnerId.get(contract.OwnerId) == null) {
                contractsByOwnerId.put(contract.OwnerId, new List<Contract__c>());
                emailAddressByUserId.put(contract.OwnerId, contract.Owner.Email);
            }
            contractsByOwnerId.get(contract.OwnerId).add(contract);

            Integer riskScore = 20;

            Decimal annualValue = contract.Annual_Value__c == null ? 0 : contract.Annual_Value__c;
            if (annualValue >= 50000) {
                riskScore += 10;
            }
            if (contract.End_Date__c <= Date.today().addDays(7)) {
                riskScore += 20;
            } else if (contract.End_Date__c > Date.today().addDays(21)) {
                riskScore -= 10;
            }

            Integer numberOfOpenTickets = ticketsByAccountId.get(contract.Account__c)?.size();
            Integer openTicketScore = 0;
            if (numberOfOpenTickets != null && numberOfOpenTickets > 0) {
                openTicketScore = numberOfOpenTickets * 5;
                if (openTicketScore > 25) {
                    openTicketScore = 25;
                }
            }

            Integer criticalScore = 0;
            List<Support_Ticket__c> supportTickets = ticketsByAccountId.get(contract.Account__c);
            if (supportTickets != null && supportTickets.size() > 0) {
                for (Support_Ticket__c supportTicket : supportTickets) {
                    if (supportTicket.Severity__c == 'High' || supportTicket.Severity__c == 'Critical') {
                        criticalScore = 15;
                        break;
                    }
                }
            }

            riskScore = riskScore + criticalScore + openTicketScore;
            if (riskScore > 100) {
                riskScore = 100;
            } else if (riskScore < 0) {
                riskScore = 0;
            }

            riskScoreByContractId.put(contract.Id, riskScore);

            if (!contractIdsToUpdate.contains(contract.Id)) {
                contractIdsToUpdate.add(contract.Id);
                contractsToUpdate.add(new Contract__c(
                        Id = contract.Id,
                        Renewal_Risk_Score__c = riskScore,
                        Last_Renewal_Notification_Date__c = Date.today()
                ));
            }
        }

        for (Id ownerId : contractsByOwnerId.keySet()) {
            List<Contract__c> ownerContracts = contractsByOwnerId.get(ownerId);

            Contract__c topContract = getTopContract(ownerContracts, riskScoreByContractId);

            String top3Text = getHighestRisks(ownerContracts, riskScoreByContractId);


            if (String.isBlank(emailAddressByUserId.get(ownerId))) {
                notificationLogs.add(new Renewal_Notification__c(
                        Contract__c = topContract == null ? null : topContract.Id,
                        Recipient__c = ownerId,
                        SentAt__c = System.now(),
                        Summary__c =
                                'SKIPPED (missing recipient email). Contracts: ' + ownerContracts.size() +
                                        (topContract == null ? '' : (', Top: ' + topContract.Id))
                ));
                continue;
            }

            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            message.setSubject('Renewal Notification');
            message.setTargetObjectId(ownerId);

            String textBody =
                    'Renewal Notification\nTOP 3 Contracts with highest risk:\n' +
                            top3Text +
                            '\nAll contracts:\n';

            for (Contract__c contract : ownerContracts) {
                textBody += contract.Account__r.Name +
                        ' - ' +
                        contract.End_Date__c +
                        ' - ' +
                        contract.Annual_Value__c +
                        ' - ' +
                        riskScoreByContractId.get(contract.Id) +
                        ' - ' +
                        (ticketsByAccountId.get(contract.Account__c) == null
                                ? '0'
                                : ticketsByAccountId.get(contract.Account__c).size().toString()
                        ) +
                        '\n';
            }

            message.setPlainTextBody(textBody);
            messages.add(message);

            // NEW: log per email
            notificationLogs.add(new Renewal_Notification__c(
                    Contract__c = topContract == null ? null : topContract.Id,
                    Recipient__c = ownerId,
                    SentAt__c = System.now(),
                    Summary__c =
                            'Contracts: ' + ownerContracts.size() +
                                    (topContract == null ? '' : (', Top: ' + topContract.Id))
            ));
        }

        Messaging.sendEmail(messages, false);

        if (!contractsToUpdate.isEmpty()) {
            update contractsToUpdate;
        }

        if (!notificationLogs.isEmpty()) {
            insert notificationLogs;
        }
    }

    private String getHighestRisks(List<Contract__c> contracts, Map<Id, Integer> riskScoreByContractId) {
        List<ContractComparator> wrapped = new List<ContractComparator>();
        for (Contract__c c : contracts) {
            wrapped.add(new ContractComparator(c, riskScoreByContractId.get(c.Id)));
        }
        wrapped.sort();

        String result = '';
        Integer minimum = Math.min(3, wrapped.size());
        for (Integer i = 0; i < minimum; i++) {
            Contract__c c = wrapped[i].contract;
            result += c.Account__r.Name + ' - ' + c.Name + ': ' + riskScoreByContractId.get(c.Id) + '\n';
        }
        return result;
    }

    private Contract__c getTopContract(List<Contract__c> contracts, Map<Id, Integer> riskScoreByContractId) {
        if (contracts == null || contracts.isEmpty()) return null;

        List<ContractComparator> wrapped = new List<ContractComparator>();
        for (Contract__c c : contracts) {
            wrapped.add(new ContractComparator(c, riskScoreByContractId.get(c.Id)));
        }
        wrapped.sort();
        return wrapped.isEmpty() ? null : wrapped[0].contract;
    }

    public void finish(Database.BatchableContext context) {
    }

    public class Scheduler implements Schedulable {
        public void execute(SchedulableContext sc) {
            Database.executeBatch(new BatchableRenewalNotifier(), 200);
        }
    }
}
