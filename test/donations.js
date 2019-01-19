var Donations = artifacts.require("Donations");
var FakeERC20 = artifacts.require("FakeERC20");

var PriceTracker = new Map();
let oneHorse = web3.toWei(1, "ether") * 1;

function logPrice(actionName, transaction) {
    if (PriceTracker.get(actionName)) {
        PriceTracker.get(actionName).push(transaction.receipt.gasUsed);
    } else {
        PriceTracker.set(actionName, [transaction.receipt.gasUsed]);
    }
}

//testing the horsey contract
contract('Donations', function (accounts) {
    /*
        HELPERS
    */
    function hex2a(hexx) {
        var hex = hexx.toString();//force conversion
        var str = '';
        for (var i = 2; (i < hex.length && hex.substr(i, 2) !== '00'); i += 2)
            str += String.fromCharCode(parseInt(hex.substr(i, 2), 16));
        return str;
    }

    async function getCost(trans) {
        const tx = await web3.eth.getTransaction(trans.tx);
        return tx.gasPrice.mul(trans.receipt.gasUsed);
    }

    let owner = accounts[1];
    let defaultUser = accounts[2];

    it("should be able to initialize contract", async () => {
        let donations = await Donations.new({ from: defaultUser });
        let receipt = await web3.eth.getTransactionReceipt(donations.transactionHash);
        PriceTracker.set("contract creation", [receipt.gasUsed]);
    });

    it("should be able to send ERC20 to the contract", async () => {
        let donations = await Donations.new({ from: owner });
        let horse = await FakeERC20.new({ from: owner });
        await horse.transfer(donations.address, oneHorse * 10000,{ from: owner });
        let amount = await horse.balanceOf(donations.address);
        console.log(amount);
    });

    it("dummy", async () => {
        console.log(PriceTracker);
    });
});