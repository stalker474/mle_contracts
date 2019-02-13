pragma solidity ^0.5.2;

import "../ethereum-api/oraclizeAPI_0.5.sol";
import "../openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../openzeppelin-solidity/contracts/ownership/Ownable.sol";

contract PriceEmpire is usingOraclize, Pausable, Ownable {

    using SafeMath for uint256;
//    using strings for *;

    /// @dev events
    event SamplingPriceStarted(bytes32 query_id);
    event SamplingPriceEnded(uint256 price, string result, bytes proof);
    event OraclizeError(uint256 value);
    event SlotPurchased(uint256 price, uint8 tier, address from, address by);
    event SlotAbandoned(uint256 price, uint8 tier, address by);

    uint256 constant PRECISION = 1000000;

    // config

    /// @dev gas limit for price callbacks
    uint256 public config_gas_limit = 200000;
    /// @dev gas price for transactions
    uint256 public config_gasprice = 20000000000 wei;
    /// @dev amount of gas to spend on oraclize update callback
    uint256 public config_update_gas_limit = 300000;
    /// @dev time between start and end price for the price movement bet
    uint256 public config_pricecheck_delay = 2 minutes;

    uint256 public config_tier3_payout = 5000; // 5000/PRECISION
    uint256 public config_tier2_payout = 500;  // 500/PRECISION
    uint256 public config_tier1_payout = 50;   // 50/PRECISION

    uint256 public config_tier3_price = 0.02 ether;
    uint256 public config_tier2_price = 0.2 ether;
    uint256 public config_tier1_price = 2 ether;

    uint256 public config_rebuy_mult = 1750000; //175%
    uint256 public config_rebuy_fee = 500000; //50%
    uint256 public config_resell_fee = 100000; //10%
    uint256 public config_hotness_modifier = 1500000;//150%
    uint256 public config_spread = 150000; // 15%
    uint256 public config_min_hotness_ratio = 300000; //30%

    /// @dev address to which send the house cut on withdrawal
    uint256 public config_house_cut = 50000; //5%
    address payable config_cut_address = 0xA54741f7fE21689B59bD7eAcBf3A2947cd3f3BD4;

    /// @dev oraclize queries for ETH,BTC and LTC with encrypted api key for cryptocompare
    string constant public query_stringETH = "[URL] json(https://min-api.cryptocompare.com/data/price?fsym=ETH&tsyms=USD&extraParams=PriceRoll&sign=true&api_key=${[decrypt] BJEWo5a53APBrN4fYpz5xJaDzPmCLNjKdU+yMeD3p6VsMLkFRFfqIvRa+d4/qukTBbsFZqkvstMMcqoLZaShoh4HfH9XQUxL7cAtKwuAi8GCkFps0kcFmNB3EAQQvgGMX4Feaaoh40YCp5qBdKgXqLhX+BVu4x9p0uKS9XXB+Cc2qIlvagkG7y+To1bVrp1Xgg==}).USD";
  
    /// @dev used for cooldown between samples
    uint256 public latest_sample = 0;
    /// @dev used to remember the latest received price
    uint256 public current_price = 0;
    /// @dev used to compute the amount of bocks since last update
    uint256 public latest_blockheight = 0;
    /// @dev total amount of collected eth by the house
    uint256 public house;
    /// @dev total amount of ETH available in pool for claiming
    uint256 public pool;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public profitOf;
    mapping(address => uint256) public capitalOf;
    mapping(address => uint256) public resell_tickets;

    mapping(uint256 => address payable) public slot_to_owner;
    mapping(uint256 => uint256) public slot_to_price;
    mapping(uint256 => uint256) public slot_to_earnings;

    /// @dev mapping to prevent processing twice the same query
    mapping(bytes32 => bool) internal _processed;
    /// @dev mapping to detect roll callbacks
    mapping(bytes32 => bool) internal _rolling_query;

    /**
        @dev init the contract
    */
    constructor() public
    Pausable()
    Ownable() {
        latest_sample = block.timestamp;
        latest_blockheight = block.number;
         oraclize_setCustomGasPrice(config_gasprice);
    }

    function newSample() public
    whenNotPaused() {
        //prevent roll spamming by respecting a minimal cooldown period
        require(latest_sample + config_pricecheck_delay <= block.timestamp, "cooling down");
        //compute oraclize fees
        uint256 call_price = _checkPrice();

        if(call_price > address(this).balance) {
            //the caller didnt send enough for oraclize fees, just push an event and display the desired price
            emit OraclizeError(call_price);
        } else {
            oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
            bytes32 queryId = oraclize_query(config_pricecheck_delay, "nested", query_stringETH, config_gas_limit);
            emit SamplingPriceStarted(queryId);

            //remove proof for simple call schedule
            oraclize_setProof(proofType_NONE);
            queryId = oraclize_query(config_pricecheck_delay, "URL", "", config_update_gas_limit);
            _rolling_query[queryId] = true;
        }
    }

    function buySlots(uint256[] calldata prices, uint8[] calldata tiers) external payable
    {
        require(prices.length == tiers.length,"Invalid input");
        require(prices.length <= 10, "Maximum 10 slots at a time");
        uint256 total_price = 0;
        for(uint8 i = 0; i < prices.length; i++) {
            total_price.add(_buySlot(prices[i],tiers[i]));
        }
        require(msg.value >= total_price,"Not enough funds");
    }

    function sellSlots(uint256[] calldata prices, uint8[] calldata tiers) external
    {
        require(prices.length == tiers.length,"Invalid input");
        require(prices.length <= 10, "Maximum 10 slots at a time");
        uint256 total_price = 0;
        uint256 resell_fee = 0;
        uint256 total_properties_req = 0;
        for(uint8 i = 0; i < prices.length; i++) {
            uint256 slot_id = _getSlotId(prices[i], tiers[i]);
            require(slot_to_owner[slot_id] == msg.sender,"Not all slots are yours");
            total_price = total_price.add(slot_to_price[slot_id]);
            resell_fee = slot_to_price[slot_id] * (config_resell_fee / PRECISION);
            total_properties_req = total_properties_req.add(_getSlotResellTickets(tiers[i]));
            delete(slot_to_price[slot_id]);
            delete(slot_to_owner[slot_id]);

            emit SlotAbandoned(prices[i], tiers[i], msg.sender);
        }
        pool = pool.sub(total_price);
        capitalOf[msg.sender] = capitalOf[msg.sender].sub(total_price);

        require(resell_tickets[msg.sender] >= total_properties_req.mul(2), "Not enough resell tickets");
        resell_tickets[msg.sender] = resell_tickets[msg.sender].sub(total_properties_req.mul(2));

        uint256 to_pay = total_price.sub(resell_fee);
        if(!msg.sender.send(to_pay)) {
            balanceOf[msg.sender] = balanceOf[msg.sender].add(to_pay);
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
        
        current_price = _stringToUintNormalize(_result);

        uint256 elapsed_blocks = block.number - latest_blockheight;

        //pay winners

        for(uint8 i = 0; i < 3; i++) {
            uint256 slot_id_tier = _getSlotId(current_price, i);
            uint256 tierPayout = _getSlotPayout(i);
            uint256 payout = pool * (tierPayout / PRECISION) * elapsed_blocks;
            slot_to_earnings[slot_id_tier] = slot_to_earnings[slot_id_tier].add(payout);

            if (slot_to_owner[slot_id_tier] != address(0)) {
                //this slot is owned by someone
                profitOf[slot_to_owner[slot_id_tier]] = profitOf[slot_to_owner[slot_id_tier]].add(payout);
                if(!slot_to_owner[slot_id_tier].send(payout)) {
                    balanceOf[slot_to_owner[slot_id_tier]] = balanceOf[slot_to_owner[slot_id_tier]].add(payout);
                }
            }
        }

        latest_sample = block.timestamp;
        latest_blockheight = block.number;

        emit SamplingPriceEnded(current_price, _result, _proof);
    }

    // the callback function is called by Oraclize when the result is ready
    function __callback(bytes32 _queryId, string memory _result) public
    { 
        require (msg.sender == oraclize_cbAddress(), "auth failed");
        require(!_processed[_queryId], "Query has already been processed!");
        _processed[_queryId] = true;
        newSample();
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
        @dev Sets the gas sent to oraclize for callback for the scheduling
        @param new_gaslimit Gas in wei
    */
    function setRollingGasLimit(uint256 new_gaslimit) external
    onlyOwner() {
        config_update_gas_limit = new_gaslimit;
    }

    /**
        @dev Sets the gas price to be used by oraclize
        @param new_gasprice Gas in wei
    */
    function setGasPrice(uint256 new_gasprice) external
    onlyOwner() {
        config_gasprice = new_gasprice;
        oraclize_setCustomGasPrice(config_gasprice);
    }

    /**
        @dev returns current oraclize fees in Wei 
    */
    function _checkPrice() internal returns (uint256) {
         //TLSNotary proof for URLs
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
        uint256 price = oraclize_getPrice("URL", config_gas_limit);
        //no proof for automatic
        oraclize_setProof(proofType_NONE);
        return price.add(oraclize_getPrice("URL", config_update_gas_limit));
    }

    function _buySlot(uint256 price, uint8 tier) internal
    whenNotPaused() returns (uint256) {
        require(tier <= 2, "maximum 2 digits precision allowed");
        require(current_price != 0,"Game hasnt started yet");
        
       
        uint256 slot_id = _getSlotId(price, tier);
       
        uint256 final_buy_price = 0;

        uint256 tickets = _getSlotResellTickets(tier);
        address from = address(0);

        if(slot_to_price[slot_id] == 0) {
            //this slot is available for purchase
            uint256 slot_price = _getSlotBasePrice(tier);
            //compute hot property modifier
            int delta = int256(price) - int256(current_price);
            uint256 absDelta = uint256(delta > 0? delta : -delta);
            require(absDelta / current_price <= (config_spread / PRECISION), "Cant buy this property yet");
            uint256 hotnessRatio = (1.0-(absDelta / current_price) / (config_spread / PRECISION)) * PRECISION;
            //clamp hotness ratio
            if(hotnessRatio < config_min_hotness_ratio) {
                hotnessRatio = config_min_hotness_ratio;
            }
            uint256 hotnessModif = slot_price * (config_hotness_modifier / PRECISION) * (hotnessRatio / PRECISION);
            final_buy_price = slot_price.add(hotnessModif);
        } else {
            //this slot belongs to someone
            //apply buy majoration
            uint256 purchase_price = slot_to_price[slot_id];
            final_buy_price = slot_to_price[slot_id]  * (config_rebuy_mult /  PRECISION);

            uint256 owner_fee = final_buy_price.sub(purchase_price) * (config_rebuy_fee / PRECISION);
            //send to owner his due
            address payable original_owner = slot_to_owner[slot_id];
            from = original_owner;

            if(resell_tickets[original_owner] > tickets) {
                resell_tickets[original_owner] = resell_tickets[original_owner].sub(tickets);
            } else if(resell_tickets[original_owner] > 0) {
                resell_tickets[original_owner] = 0;
            }
            
            profitOf[original_owner] = profitOf[original_owner].add(owner_fee);

            if(!original_owner.send(purchase_price.add(owner_fee))) {
                balanceOf[original_owner] = balanceOf[original_owner].add(purchase_price.add(owner_fee));
            }
        }

        uint256 house_fee = final_buy_price * (config_house_cut / PRECISION);
        uint256 estate_price = final_buy_price.sub(house_fee);
        pool = pool.add(estate_price);
        house = house.add(house_fee);
        
        slot_to_price[slot_id] = estate_price;
        slot_to_owner[slot_id] = msg.sender;
        capitalOf[msg.sender] = capitalOf[msg.sender].add(estate_price);

        resell_tickets[msg.sender] = resell_tickets[msg.sender].add(tickets);

        emit SlotPurchased(price, tier, from, msg.sender);

        return final_buy_price;
    }

    function _getSlotId(uint256 price, uint8 tier) internal returns (uint256) {
        //trim the price based on tier to prevent multiple slots of same price being a city
        //example a tier 0 must end with "00" and a tier 1 with "0"
        if(tier == 0)
            price = uint256(price / 100) * 100;
        else if(tier == 1)
            price = uint256(price / 10) * 10;

        return uint256(keccak256(abi.encodePacked(price, tier)));
    }

    function _getSlotBasePrice(uint8 tier) internal view returns (uint256) {
        require(tier <= 2, "maximum 2 digits precision allowed");
        if(tier == 2) {
            return config_tier3_price;
        } else if(tier == 1) {
            return config_tier2_price;
        } else {
            return config_tier1_price;
        }
    }

    function _getSlotPayout(uint8 tier) internal view returns (uint256) {
        require(tier <= 2, "maximum 2 digits precision allowed");
        if(tier == 2) {
            return config_tier3_payout;
        } else if(tier == 1) {
            return config_tier2_payout;
        } else {
            return config_tier1_payout;
        }
    }

    function _getSlotResellTickets(uint8 tier) internal view returns (uint256) {
        require(tier <= 2, "maximum 2 digits precision allowed");
        if(tier == 2) {
            return 1;
        } else if(tier == 1) {
            return 10;
        } else {
            return 100;
        }
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