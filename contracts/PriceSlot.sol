pragma solidity ^0.5.2;

import "../ethereum-api/oraclizeAPI_0.5.sol";
import "../openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../openzeppelin-solidity/contracts/ownership/Ownable.sol";

contract PriceSlot is usingOraclize, Pausable, Ownable {

    using SafeMath for uint256;
//    using strings for *;

    /// @dev events
    event SamplingPriceStarted(bytes32 query_id);
    event SamplingPriceEnded(uint256 price, string result, bytes proof);
    event OraclizeError(uint256 value);

    // config

    /// @dev time before a started roll has to reach the DONE state before it can be refunded
    uint256 public config_refund_delay = 50 minutes;
    /// @dev gas limit for price callbacks
    uint256 public config_gas_limit = 200000;
    /// @dev time between start and end price for the price movement bet
    uint256 public config_pricecheck_delay = 1 minutes;
    uint256 public config_tier3_payout = 500; // 500/100000
    uint256 public config_tier2_payout = 50;  // 50/100000
    uint256 public config_tier1_payout = 5;   // 5/100000

    uint256 public config_tier3_price = 0.01 ether;
    uint256 public config_tier2_price = 0.1 ether;
    uint256 public config_tier1_price = 1 ether;

    uint256 public config_rebuy_mult = 150; //150%
    uint256 public config_rebuy_fee = 50; //50%
    /// @dev address to which send the house cut on withdrawal
    uint256 public config_house_cut = 5; //5%
    address payable config_cut_address = 0xA54741f7fE21689B59bD7eAcBf3A2947cd3f3BD4;

    /// @dev oraclize queries for ETH,BTC and LTC with encrypted api key for cryptocompare
    string constant public query_stringLTC = "[URL] json(https://min-api.cryptocompare.com/data/price?fsym=LTC&tsyms=USD&extraParams=PriceRoll&sign=true&api_key=${[decrypt] BJEWo5a53APBrN4fYpz5xJaDzPmCLNjKdU+yMeD3p6VsMLkFRFfqIvRa+d4/qukTBbsFZqkvstMMcqoLZaShoh4HfH9XQUxL7cAtKwuAi8GCkFps0kcFmNB3EAQQvgGMX4Feaaoh40YCp5qBdKgXqLhX+BVu4x9p0uKS9XXB+Cc2qIlvagkG7y+To1bVrp1Xgg==}).USD";
  
    /// @dev used for cooldown between samples
    uint256 public latest_sample = 0;
    /// @dev total amount of collected eth by the house
    uint256 public house;
    /// @dev total amount of ETH available in pool for claiming
    uint256 public pool;

    mapping(address => uint256) public balanceOf;

    mapping(uint256 => address payable) public slot_to_owner;
    mapping(address => uint256) public owner_to_slot;
    /// @dev mapping to prevent processing twice the same query
    mapping(bytes32 => bool) internal _processed;

    /**
        @dev init the contract
    */
    constructor() public
    Pausable()
    Ownable() {
        //set proof only once
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
    }

    function newSample() external payable
    whenNotPaused() {
        //prevent roll spamming by respecting a minimal cooldown period
        require(latest_sample + config_pricecheck_delay <= block.timestamp, "cooling down");
        //compute oraclize fees
        uint256 call_price = _checkPrice();

        if(call_price > msg.value) {
            //the caller didnt send enough for oraclize fees, just push an event and display the desired price
            emit OraclizeError(call_price);
            //send back the eth!
            if(msg.value > 0) {
                msg.sender.transfer(msg.value);
            }
        } else {
            bytes32 queryId = oraclize_query(config_pricecheck_delay, "nested", query_stringLTC, config_gas_limit);

            //send some value back if left
            uint256 remains = msg.value.sub(call_price);
            if(remains > 0) {
                msg.sender.transfer(remains);
            }

            emit SamplingPriceStarted(queryId);
        }
    }

    function buySlot(uint256 price, uint8 precision) external payable
    whenNotPaused() {
        require(precision <= 2, "maximum 2 digits precision allowed");
        uint256 slot_price = _getSlotBasePrice(precision);
       

        uint256 slot_id = price;
        if (precision == 0) {
            slot_id = slot_id / 100;
        } else if(precision == 1) {
             slot_id = slot_id / 10;
        }
        address payable original_owner = slot_to_owner[slot_id];
        if(original_owner == address(0)) {
            //this slot is available for purchase
             require(msg.value >= slot_price,"Not enough ETH sent");
             uint256 house_fee = slot_price / 100 * config_house_cut;
             pool = pool.add(msg.value.sub(house_fee));
             house = house.add(house_fee);
            
        } else {
            //this slot belongs to someone
            //apply buy majoration
            uint256 slot_price_rebuy = slot_price / 100 * config_rebuy_mult;
            require(msg.value >= slot_price_rebuy,"Not enough ETH sent");
            uint256 owner_fee = slot_price_rebuy.sub(slot_price) /100 * config_rebuy_fee;
            if(!original_owner.send(owner_fee)) {
                balanceOf[original_owner] = balanceOf[original_owner].add(owner_fee);
            }

            uint256 house_fee = slot_price_rebuy / 100 * config_house_cut;
            pool = pool.add(slot_price_rebuy.sub(house_fee).sub(owner_fee));
            house = house.add(house_fee);
        }
        //send some value back if left
        uint256 remains = msg.value.sub(slot_price);
        if(remains > 0) {
            msg.sender.transfer(remains);
        }
    }

    function _getSlotBasePrice(uint8 precision) internal view returns (uint256) {
        require(precision <= 2, "maximum 2 digits precision allowed");
        if(precision == 2) {
            return config_tier3_price;
        } else if(precision == 1) {
            return config_tier2_price;
        } else {
            return config_tier1_price;
        }
    }

    /// @dev fallback for accepting funding and replenish the pool
    function () external payable {
        //used for provisionning pool
        pool = pool.add(msg.value);
    }

    /**
        @dev Allows to withdraw an amount from callers internal wallet
        @param amount Amount to withdraw in Wei
    */
    function withdrawWallet(uint256 amount) external
    {
        require(balanceOf[msg.sender] >= amount, "Not enough funds");
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(amount);
        msg.sender.transfer(amount);
    }

    /// @dev only test!!!!!!!! REMOVE FOR MAINNET
    function destroy() external
    onlyOwner() {
        // send the contracts balance to the caller
        selfdestruct(msg.sender);
    }

    // the callback function is called by Oraclize when the result is ready
    function __callback(bytes32 _queryId, string memory _result, bytes memory _proof) public
    { 
        require (msg.sender == oraclize_cbAddress(), "auth failed");
        require(!_processed[_queryId], "Query has already been processed!");
        _processed[_queryId] = true;
        
        uint256 price = _stringToUintNormalize(_result);
        uint256 tier1Slot = price / 100;
        uint256 tier2Slot = price / 10;
        uint256 tier3Slot = price;

        //pay winners
        if (slot_to_owner[tier1Slot] != address(0)) {
            //this slot is owned by someone
            uint256 payout = pool.div(100000).mul(config_tier1_payout);
            if(!slot_to_owner[tier1Slot].send(payout)) {
                balanceOf[slot_to_owner[tier1Slot]] = balanceOf[slot_to_owner[tier1Slot]].add(payout);
            }
        }

        if (slot_to_owner[tier2Slot] != address(0)) {
            //this slot is owned by someone
            uint256 payout = pool.div(100000).mul(config_tier2_payout);
            if(!slot_to_owner[tier2Slot].send(payout)) {
                balanceOf[slot_to_owner[tier2Slot]] = balanceOf[slot_to_owner[tier2Slot]].add(payout);
            }
        }

        if (slot_to_owner[tier3Slot] != address(0)) {
            //this slot is owned by someone
            uint256 payout = pool.div(100000).mul(config_tier3_payout);
            if(!slot_to_owner[tier3Slot].send(payout)) {
                balanceOf[slot_to_owner[tier3Slot]] = balanceOf[slot_to_owner[tier3Slot]].add(payout);
            }
        }

        latest_sample = block.timestamp;

        emit SamplingPriceEnded(price, _result, _proof);
    }

    /**
        @dev Sends the required amount to the cut address
        @param amount Amount to withdraw from the house in Wei
    */
    function withdrawHouse(uint256 amount) external
    onlyOwner() {
        require(house >= amount, "Cant withdraw that much");
        house = house.sub(amount);
        config_cut_address.transfer(amount);
    }

    /**
        @dev Address of destination for the house edge
        @param new_desination address to send eth to
    */
    function setCutDestination(address payable new_desination) external
    onlyOwner() {
        config_cut_address = new_desination;
    }

    /**
        @dev Sets the gas sent to oraclize for callback on a single price check
        @param new_gaslimit Gas in wei
    */
    function setGasLimit(uint256 new_gaslimit) external
    onlyOwner() {
        config_gas_limit = new_gaslimit;
    }

    /**
        @dev Sets the delay between oraclize price request calls
        @param new_delay Delay in seconds
    */
    function setPriceCheckDelay(uint256 new_delay) external
    onlyOwner() {
        require(new_delay < 60 days,"Oraclize delay is maximum 60 days");
        config_pricecheck_delay = new_delay;
    }

    /**
        @dev returns current oraclize fees in Wei 
    */
    function _checkPrice() internal returns (uint256) {
        //TLSNotary proof for URLs
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
        return oraclize_getPrice("URL", config_gas_limit);
    }

    //ETHORSE CODE
    // utility function to convert string to integer with precision consideration
    function _stringToUintNormalize(string memory s) internal pure returns (uint result) {
        uint p = 2;
        bool precision = false;
        bytes memory b = bytes(s);
        uint i;
        result = 0;
        for (i = 0; i < b.length; i++) {
            if (precision) {p = p-1;}
            if (uint8(b[i]) == 46){precision = true;}
            uint c = uint8(b[i]);
            if (c >= 48 && c <= 57) {result = result * 10 + (c - 48);}
            if (precision && p == 0){return result;}
        }
        while (p!=0) {
            result = result*10;
            p = p-1;
        }
    }

}