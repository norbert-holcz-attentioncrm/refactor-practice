/**
 * Created by norbe on 2026. 02. 15..
 */

public class ContractComparator implements Comparable {

    public Contract__c contract;
    public Integer riskScore;

    public ContractComparator(Contract__c contract, Integer riskScore) {
        this.contract = contract;
        this.riskScore = riskScore;
    }

    public Integer compareTo(Object other) {
        ContractComparator o = (ContractComparator) other;

        Integer thisScore = this.riskScore == null ? 0 : this.riskScore;
        Integer otherScore = o.riskScore == null ? 0 : o.riskScore;

        if (thisScore == otherScore) return 0;
        return thisScore > otherScore ? -1 : 1;
    }
}
