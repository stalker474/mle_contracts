var Donations = artifacts.require("Donations");
var FakeERC20 = artifacts.require("FakeERC20");

var PriceTracker = new Map();

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
    let oneHorse = web3.utils.toBN(web3.utils.toWei("1", "ether"));

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

    /*it("should be able to initialize contract", async () => {
        let addresses =  [accounts[0],accounts[1],accounts[2],accounts[3],accounts[4]];
        let donations = await Donations.new(addresses, { from: owner });
        let receipt = await web3.eth.getTransactionReceipt(donations.transactionHash);
        PriceTracker.set("contract creation", [receipt.gasUsed]);
    });

    it("should be able to send ERC20 to the contract", async () => {
        let addresses =  [accounts[0],accounts[1],accounts[2],accounts[3],accounts[4]];
        let donations = await Donations.new(addresses, { from: owner });
        let horse = await FakeERC20.new({ from: owner });
        await horse.transfer(donations.address, web3.utils.toWei("10000", "ether"),{ from: owner });
        let amount = await horse.balanceOf(donations.address);
        assert.equal(amount,web3.utils.toWei("10000", "ether"));
    });

    it("should be able to send ETH to the contract", async () => {
        let addresses =  [accounts[0],accounts[1],accounts[2],accounts[3],accounts[4]];
        let donations = await Donations.new(addresses, { from: owner });
        await web3.eth.sendTransaction({from : owner, to : donations.address, value : web3.utils.toWei("1","ether")});
        
        let amount = await web3.eth.getBalance(donations.address);
        assert.equal(amount,web3.utils.toWei("1", "ether"));
    });*/

    it("should be able to withdraw from donations", async () => {
        let horse = await FakeERC20.new({ from: owner });
        let addresses =  [accounts[0],accounts[1],accounts[2],accounts[3],accounts[4],horse.address];
        let donations = await Donations.new(addresses, { from: owner });
       
        let totalETH = 0;
        let totalHORSE = 0;

        let amountETHAccBefore = await web3.eth.getBalance(accounts[0]);
        let amountHORSEAccBefore = await horse.balanceOf(accounts[0]);

        for(let i = 0; i < 50; i++) {
            let rand = Math.floor(Math.random()*3);
            
            console.log(rand);
            if(rand == 0) {
                let am = Math.floor(Math.random()*1000);
                await web3.eth.sendTransaction({from : owner, to : donations.address, value : web3.utils.toWei(""+(am/1000),"ether")});
                totalETH += am / 1000;
            } else if(rand == 1) {
                let am = Math.floor(Math.random()*1000);
                await horse.transfer(donations.address, web3.utils.toWei(""+am, "ether"),{ from: owner });
                totalHORSE += am;
            } else {
                await donations.withdraw({from : accounts[0]});
            }

            await donations.withdraw({from : accounts[0]});

            let amountETH = await web3.eth.getBalance(donations.address);
            let amountHORSE = await horse.balanceOf(donations.address);
            let amountETHAcc = await web3.eth.getBalance(accounts[0]);
            let amountHORSEAcc = await horse.balanceOf(accounts[0]);

            console.log("total eth sent: "+totalETH + " total eth in contract: " + web3.utils.fromWei(amountETH,"ether"));
            console.log("total HORSE sent: "+totalHORSE + " total HORSE in contract: " + web3.utils.fromWei(amountHORSE, "ether"));
            console.log("amount of ETH owned before: " + web3.utils.fromWei(amountETHAccBefore,"ether") + " amount of ETH owned after: " + web3.utils.fromWei(amountETHAcc,"ether"));
            console.log("amount of HORSE owned before : " + web3.utils.fromWei(amountHORSEAccBefore,"ether") + " amount of HORSE owned after: " + web3.utils.fromWei(amountHORSEAcc,"ether"));

            let tr = await donations.checkBalance({from: accounts[0] });
            console.log("ETH: " + web3.utils.fromWei(web3.utils.toBN(tr[0]),"ether") + " HORSE: " + web3.utils.fromWei(web3.utils.toBN(tr[1]),"ether"));
            tr = await donations.checkBalance({from: accounts[1] });
            console.log("ETH: " + web3.utils.fromWei(web3.utils.toBN(tr[0]),"ether") + " HORSE: " + web3.utils.fromWei(web3.utils.toBN(tr[1]),"ether"));
            tr = await donations.checkBalance({from: accounts[2] });
            console.log("ETH: " + web3.utils.fromWei(web3.utils.toBN(tr[0]),"ether") + " HORSE: " + web3.utils.fromWei(web3.utils.toBN(tr[1]),"ether"));
            tr = await donations.checkBalance({from: accounts[3] });
            console.log("ETH: " + web3.utils.fromWei(web3.utils.toBN(tr[0]),"ether") + " HORSE: " + web3.utils.fromWei(web3.utils.toBN(tr[1]),"ether"));
            tr = await donations.checkBalance({from: accounts[4] });
            console.log("ETH: " + web3.utils.fromWei(web3.utils.toBN(tr[0]),"ether") + " HORSE: " + web3.utils.fromWei(web3.utils.toBN(tr[1]),"ether"));
        }
        
    });

    it("dummy", async () => {
        console.log(PriceTracker);
    });
});