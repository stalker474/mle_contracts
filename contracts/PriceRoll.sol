pragma solidity ^0.5.2;

import "../ethereum-api/oraclizeAPI_0.5.sol";
import "../openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../openzeppelin-solidity/contracts/ownership/Ownable.sol";
//import "../solidity-stringutils/src/strings.sol";

contract PriceRoll is usingOraclize, Pausable, Ownable {

    using SafeMath for uint256;
//    using strings for *;

    /// @dev events
    event Rolling(uint256 round);
    event NewRoll(uint256 round);
    event RollEnded(uint256 round, uint256 start_price, uint256 end_price, bytes1 seed);
    event RollRefunded(uint256 round);
    event RollClaimed(uint256 round, address player, uint256 amount);
    event BetPlaced(uint256 round, uint256 amount, address player, uint8 expected_value, uint8 is_up);
    event OraclizeError(uint256 value);
    event NoPlayersError();


    // config

    /// @dev minimum time between rolls
    uint256 public config_roll_cooldown = 1 minutes;
    /// @dev time before a started roll has to reach the DONE state before it can be refunded
    uint256 public config_refund_delay = 50 minutes;
    /// @dev gas limit for price callbacks
    uint256 public config_gas_limit = 160000;
    /// @dev gas limit for random value callback
    uint256 public config_random_gas_limit = 200000;
    /// @dev gas limit for the newRoll scheduled call
    uint256 public config_rolling_gas_limit = 700000;
    /// @dev minimum authorized bet
    uint256 public config_min_bet = 0.02 ether;
    /// @dev maximum authorized bet
    uint256 public config_max_bet = 100 ether;
    /// @dev house edge
    uint256 public config_house_edge = 20; //2.0%
    /// @dev bonus to bettors winnings if he guesses the price movement
    uint256 public config_bonus_mult = 75; //7.5%
    /// @dev percentage of current pool to be used to compute max bet
    uint256 public config_percent_pool = 50; //50%
    /// @dev time between start and end price for the price movement bet
    uint256 public config_pricecheck_delay = 1 minutes;
    /// @dev address to which send the house cut on withdrawal
    address payable config_cut_address = 0xA54741f7fE21689B59bD7eAcBf3A2947cd3f3BD4;

    /// @dev possible states of a roll
    enum State {READY, WAITING_QUERY1, WAITING_QUERY2, WAITING_QUERY3, DONE, REFUND}
    /// @dev coins in the coin rotation
    enum CoinRotation {ETHEREUM, BITCOIN, LITECOIN}
    uint8 constant coin_count = 3;

    /// @dev oraclize queries for ETH,BTC and LTC with encrypted api key for cryptocompare
    string constant public query_stringETH = "[URL] json(https://min-api.cryptocompare.com/data/price?fsym=ETH&tsyms=USD&extraParams=PriceRoll&sign=true&api_key=${[decrypt] BJEWo5a53APBrN4fYpz5xJaDzPmCLNjKdU+yMeD3p6VsMLkFRFfqIvRa+d4/qukTBbsFZqkvstMMcqoLZaShoh4HfH9XQUxL7cAtKwuAi8GCkFps0kcFmNB3EAQQvgGMX4Feaaoh40YCp5qBdKgXqLhX+BVu4x9p0uKS9XXB+Cc2qIlvagkG7y+To1bVrp1Xgg==}).USD";
    string constant public query_stringBTC = "[URL] json(https://min-api.cryptocompare.com/data/price?fsym=BTC&tsyms=USD&extraParams=PriceRoll&sign=true&api_key=${[decrypt] BJEWo5a53APBrN4fYpz5xJaDzPmCLNjKdU+yMeD3p6VsMLkFRFfqIvRa+d4/qukTBbsFZqkvstMMcqoLZaShoh4HfH9XQUxL7cAtKwuAi8GCkFps0kcFmNB3EAQQvgGMX4Feaaoh40YCp5qBdKgXqLhX+BVu4x9p0uKS9XXB+Cc2qIlvagkG7y+To1bVrp1Xgg==}).USD";
    string constant public query_stringLTC = "[URL] json(https://min-api.cryptocompare.com/data/price?fsym=LTC&tsyms=USD&extraParams=PriceRoll&sign=true&api_key=${[decrypt] BJEWo5a53APBrN4fYpz5xJaDzPmCLNjKdU+yMeD3p6VsMLkFRFfqIvRa+d4/qukTBbsFZqkvstMMcqoLZaShoh4HfH9XQUxL7cAtKwuAi8GCkFps0kcFmNB3EAQQvgGMX4Feaaoh40YCp5qBdKgXqLhX+BVu4x9p0uKS9XXB+Cc2qIlvagkG7y+To1bVrp1Xgg==}).USD";
  
    /// @dev current roll id
    uint256 public current_roll = 0;
    /// @dev used for cooldown between rolls
    uint256 public latest_roll = 0;
    /// @dev used to rotate between coins for each roll
    CoinRotation public current_coin = CoinRotation.ETHEREUM;
    /// @dev total amount of collected eth by the house
    uint256 public house;
    /// @dev total amount of ETH available in pool for claiming
    uint256 public pool;

    /// @dev describes a user bet
    struct Bet {
        //amount of wagered ETH in Wei
        uint256 amount;
        //selected roll value
        uint8 value;
        //selected price movement
        bool is_up;
    }

    /// @dev describes a roll
    struct Roll {
        // oraclize query ids
        bytes32 query_rng;
        bytes32 query_price1;
        bytes32 query_price2;
        // query results
        uint256 result_price1;
        uint256 result_price2;
        //uint256 result_timestamp1;
        //uint256 result_timestamp2;
        // timestamp at the moment of the roll
        uint256 timestamp;
        // total amount of ETH wagered on this roll
        uint256 pool;
        // current state
        State state;
        // coin selected for this roll from the coin rotation
        CoinRotation coin;
        // final result of the price movement
        bool is_up;
        // final result of the random query
        bytes1 result_rngseed;
        // mapping bettors to their bets on this roll
        mapping(address => Bet) bets;
    }

    /// @dev mapping to associate roll number with a roll object
    mapping(uint256 => Roll) public rolls;
    /// @dev mapping to find the roll number associated with a query
    mapping(bytes32 => uint256) internal _query_to_roll;
    /// @dev mapping to prevent processing twice the same query
    mapping(bytes32 => bool) internal _processed;
    /// @dev mapping to detect roll callbacks
    mapping(bytes32 => bool) internal _rolling_query;
    /// @dev internal wallet
    mapping(address => uint256) public balanceOf;

    /**
        @dev init the contract and the first roll
    */
    constructor() public
    Pausable()
    Ownable() {
        //init first roll
        _generateRoll();
    }

    /**
        @dev Execute a new roll. Anyone can pay the ETH for it
        So can be called if Ethouse fails to call it automatically
        Must be provided with enough eth for Oraclize calls (see _checkPrice())
        Cant be called when paused
    */
    function newRoll() public
    whenNotPaused() {
        //prevent roll spamming by respecting a minimal cooldown period
        require(latest_roll + config_roll_cooldown <= block.timestamp, "roll is cooling down");
        //compute oraclize fees
        uint256 call_price = _checkPrice();

        if(call_price > address(this).balance) {
            //the caller didnt send enough for oraclize fees, just push an event and display the desired price
            emit OraclizeError(call_price);
        } else {
            //lets roll!
            Roll storage roll = rolls[current_roll]; 
            //check that we have players
            if(roll.pool > 0) {
                //decide on the query to use based on the coin rotation
                string memory query;
                if(current_coin == CoinRotation.ETHEREUM) {
                    query = query_stringETH;
                } else if(current_coin == CoinRotation.BITCOIN) {
                    query = query_stringBTC;
                } else {
                    query = query_stringLTC;
                }
                //use special proof for price values queries
                oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
                //save the oraclize query indices for proof 
                roll.query_price1 = oraclize_query(0, "nested", query, config_gas_limit);
                roll.query_price2 = oraclize_query(config_pricecheck_delay, "nested", query, config_gas_limit);
                //only ledger proof for random source
                oraclize_setProof(proofType_Ledger);
                roll.query_rng = oraclize_newRandomDSQuery(0, 1, config_random_gas_limit);

                
                roll.timestamp = block.timestamp;
                roll.state = State.WAITING_QUERY1;
                roll.coin = current_coin;

                //save mappings to find the right roll number associated with this query
                _query_to_roll[roll.query_rng] = current_roll;
                _query_to_roll[roll.query_price1] = current_roll;
                _query_to_roll[roll.query_price2] = current_roll;

                //begin new roll
                emit Rolling(current_roll);

                _generateRoll();
            
                //remove proof for simple call schedule
                oraclize_setProof(proofType_NONE);
                bytes32 id = oraclize_query(config_roll_cooldown, "URL", "", config_rolling_gas_limit);
                _rolling_query[id] = true;
            } else {
                //no players
                emit NoPlayersError();
            }
        }
    }

    /**
        @dev Places a bet on the current roll with using internal wallet ETH
        Cant be called when paused
        @param amount Amount to bet in Wei
        @param expected_value : integer from 2 to 99
        @param is_up : true if the expected price change is positive, false overwise
    */
    function betFromInternalWallet(uint256 amount, uint8 expected_value, bool is_up) public 
    whenNotPaused() {
        require(balanceOf[msg.sender] >= amount, "Not enough to bet the specified amount");
        require(expected_value > 1 && expected_value < 100,"Expected value must be in the range of 2 to 99");
        require(amount <= config_max_bet,"Bet too high");
        require(amount >= config_min_bet,"Bet too low");

        Roll storage roll = rolls[current_roll]; 
        Bet storage bet = roll.bets[msg.sender];

        //the bet structure must be by default at this point
        require(bet.amount == 0, "Already placed a bet");

        bet.amount = amount;
        bet.value = expected_value;
        bet.is_up = is_up;

        //compute max winnings
        uint256 win = _computeRollWithEdge(bet);
        uint256 bonus = bet.amount.mul(config_bonus_mult).div(1000);
        //check that the current pool is high enough for this kind of bet
        uint256 adjustedPool = pool / 100 * config_percent_pool;
        require(adjustedPool >= win.add(bonus),"Not enough in pool for this bet");
        //remove the bet amount from the users internal wallet
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(amount);
        //add the bet amount to the pool
        roll.pool = roll.pool.add(bet.amount);

        emit BetPlaced(current_roll, amount, msg.sender, expected_value, is_up? 1 : 0);

        //if cooled down, roll now
        if(latest_roll + config_roll_cooldown <= block.timestamp) {
            newRoll();
        }
    }

    /**
        @dev Allows to place a bet on the current roll with paid ETH
        @param expected_value : integer from 2 to 99
        @param is_up : true if the expected price change is positive, false overwise
    */
    function placeBet(uint8 expected_value, bool is_up) external payable {
        //add to internal wallet 
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
        //place a bet using internal wallet
        betFromInternalWallet(msg.value, expected_value, is_up);
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

    /**
        @dev Allows a user to add ETH directly to his internal wallet
    */
    function creditWallet() external payable
    {
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    }

    /**
        @dev Allows to claim the winnings from a roll round
        @param round Round number of the roll to claim from
    */
    function claim(uint256 round) external {
        Roll storage roll = rolls[round]; 
        Bet storage bet = roll.bets[msg.sender];
        //bettors have a non zero value bet
        require(bet.value > 0,"not a bettor");

        //handle refunding if contract isnt in the DONE or REFUND state after the refund delay is passed
        //also prevent refunding not started rolls
        if(roll.state != State.DONE && roll.state != State.REFUND && roll.state != State.READY) {
            //allow refund after the delay has passed
            bool forced_refund = roll.timestamp + config_refund_delay < now;
            if(forced_refund) {
                roll.state = State.REFUND;
            }
        }
        
        //handle payments from refunded rolls
        if(roll.state == State.REFUND) {
            //bets are deleted on refund, so bet.amount should be non zero only BEFORE refund
            require(bet.amount > 0, "Already refunded");
            //increase the internal balance of this user by the bet amount
            balanceOf[msg.sender] = balanceOf[msg.sender].add(bet.amount);
            //delete the bet from the bets mapping of this roll
            delete(roll.bets[msg.sender]);
        } else {
            //extract the users random value by using the random source and users address
            //this should guarantee diff results for every user even though the random seed is the same
            uint randomNumber = uint(keccak256(abi.encodePacked(roll.result_rngseed, msg.sender))) % 100 + 1;
            bool guessed_random = randomNumber < bet.value;
            bool guessed_pricemov = bet.is_up == roll.is_up; 
            require(guessed_random || guessed_pricemov, "No winnings to claim");
            //compute how much to pay
            uint256 to_pay = 0;
            //compute house edge on his bet
            uint256 edge = _computeRollEdge(bet);
            if(guessed_random) {
                //the user guessed right, he wins the roll formula minus house edge
                to_pay = to_pay.add(_computeRollWin(bet).sub(edge));
            }
            if(guessed_pricemov) {
                //the user guessed the price movement, add the bonus
                to_pay = to_pay.add(bet.amount.mul(config_bonus_mult).div(1000));
            }
            // credit the users internal wallet
            balanceOf[msg.sender] = balanceOf[msg.sender].add(to_pay);
            // remove the paid amount from available pool
            pool = pool.sub(to_pay);
            // edge goes to house
            house = house.add(edge);

            emit RollClaimed(round,msg.sender,to_pay);
        }
    }

    /// @dev fallback for accepting funding and replenish the pool
    function () external payable {
        //used for provisionning pool
        pool = pool.add(msg.value);
    }

    /// @dev only test!!!!!!!! REMOVE FOR MAINNET
    function destroy() external
    onlyOwner() {
        // send the contracts balance to the caller
        selfdestruct(msg.sender);
    }

    /// @dev return Current internal wallet balance of the caller in wei
    function userBalance() view external returns (uint256) {
        return balanceOf[msg.sender];
    }

    // the callback function is called by Oraclize when the result is ready
    // the oraclize_randomDS_proofVerify modifier prevents an invalid proof to execute this function code:
    // the proof validity is fully verified on-chain
    function __callback(bytes32 _queryId, string memory _result, bytes memory _proof) public
    { 
        require (msg.sender == oraclize_cbAddress(), "auth failed");
        require(!_processed[_queryId], "Query has already been processed!");
        _processed[_queryId] = true;

        if (_rolling_query[_queryId]) {
            newRoll();
        } else {
            //fetch the roll associated with this query
            uint256 roll_id = _query_to_roll[_queryId];
            require(roll_id > 0, "Invalid _queryId");
            Roll storage roll = rolls[roll_id];
            //identify if this is a query for random value, or prices check
            if(_queryId == roll.query_rng) {
                //verify proof of random on chain
                if (oraclize_randomDS_proofVerify__returnCode(_queryId, _result, _proof) != 0) {
                    // the proof verification has failed, the roll goes to refund
                    roll.state = State.REFUND;
                    emit RollRefunded(roll_id);
                } else {
                    // proof ok, save the bytes value
                    roll.result_rngseed = bytes(_result)[0];
                    // increment state to show we're waiting for the next queries now
                    roll.state = State(uint(roll.state) + 1);
                }
            } else if(_queryId == roll.query_price1) {
                //parse the result string for the precision normalized value
                roll.result_price1 = _stringToUintNormalize(_result);
                //(roll.result_price1, roll.result_timestamp1) = _extract(_result);
                // increment state to show we're waiting for the next queries now
                roll.state = State(uint(roll.state) + 1);
            } else if(_queryId == roll.query_price2) {
                //parse the result string for the precision normalized value
                roll.result_price2 = _stringToUintNormalize(_result);
                //(roll.result_price2, roll.result_timestamp2) = _extract(_result);
                // increment state to show we're waiting for the next queries now
                roll.state = State(uint(roll.state) + 1);
            } else {

                //fatal error
                roll.state = State.REFUND;
                emit RollRefunded(roll_id);
            }
            //if the roll state has been incremented enough (3 times), we've finished
            if(roll.state == State.DONE) {
                //check price change
                roll.is_up = roll.result_price1 < roll.result_price2;
                //add the rolls pool into contracts pool
                //from now on this amount of ETH can be withdrawn from the contract!
                pool = pool.add(roll.pool);
                emit RollEnded(roll_id, roll.result_price1, roll.result_price2, roll.result_rngseed);
            }
        }
        
    }

    // the callback function is called by Oraclize when the result is ready
    function __callback(bytes32 _queryId, string memory _result) public
    { 
        require (msg.sender == oraclize_cbAddress(), "auth failed");
        require(!_processed[_queryId], "Query has already been processed!");
        _processed[_queryId] = true;
        newRoll();
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
        @dev Sets the house edge
        @param new_edge Edge expressed in /1000
    */
    function setHouseEdge(uint256 new_edge) external
    onlyOwner() {
        require(new_edge <= 50,"max 5%");
        config_house_edge = new_edge;
    }

    /** 
        @dev Sets the bonus when a user guesses the price change
        @param new_bonus Bonus expressed in /1000
    */
    function setBonus(uint256 new_bonus) external
    onlyOwner() {
        require(new_bonus <= 500,"max 50%");
        config_bonus_mult = new_bonus;
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
        @dev Sets the cooldown between 2 bets
        A new roll cant be executed if the required cooldown delay since the last roll hasnt passed
        @param new_cooldown Cooldown in seconds
    */
    function setCooldown(uint256 new_cooldown) external
    onlyOwner() {
        require(new_cooldown >= 1 minutes,"Minimum is 1 minute");
        config_roll_cooldown = new_cooldown;
    }

    /**
        @dev Sets the minimum allowed bet
        @param new_minbet Minimum allowed bet in Wei
    */
    function setMinBet(uint256 new_minbet) external
    onlyOwner() {
        require(new_minbet > 0, "Must be greater than zero");
        config_min_bet = new_minbet;
    }

    /**
        @dev Sets the maximum allowed bet
        @param new_maxbet Maximum allowed bet in Wei
    */
    function setMaxBet(uint256 new_maxbet) external
    onlyOwner() {
        require(new_maxbet > 0, "Must be greater than zero");
        config_max_bet = new_maxbet;
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
        @dev Sets the gas sent to oraclize for callback on the random value
        @param new_gaslimit Gas in wei
    */
    function setRandomGasLimit(uint256 new_gaslimit) external
    onlyOwner() {
        config_random_gas_limit = new_gaslimit;
    }

    /**
        @dev Sets the gas sent to oraclize for callback for the rolling scheduling
        @param new_gaslimit Gas in wei
    */
    function setRollingGasLimit(uint256 new_gaslimit) external
    onlyOwner() {
        config_rolling_gas_limit = new_gaslimit;
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
        @dev Increments the current roll and rotates the coin
        After this call, all bets go to the new roll pool
    */
    function _generateRoll() internal {
        current_roll = current_roll.add(1);
        current_coin = CoinRotation((uint(current_coin)+1)%coin_count);
        latest_roll = block.timestamp;

        emit NewRoll(current_roll);
    }

    /**
        @dev returns current oraclize fees in Wei 
    */
    function _checkPrice() internal returns (uint256) {
        //TLSNotary proof for URLs
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
        uint256 call_price = oraclize_getPrice("URL", config_gas_limit) * 2; //2 calls
        oraclize_setProof(proofType_Ledger);
        call_price = call_price.add(oraclize_getPrice("Random", config_random_gas_limit)); //1 call

        oraclize_setProof(proofType_NONE);
        return call_price.add(oraclize_getPrice("URL", config_rolling_gas_limit)); //1 call
    }

     /**
        @dev Computes the total winnings of a bet before applying the house edge
        @param bet a potentially winning bet
    */
    function _computeRollWin(Bet memory bet) internal pure returns (uint256) {
        uint256 odds = uint256(bet.value) - 1;
        return (((bet.amount * (100-odds)) / odds + bet.amount));
    }

     /**
        @dev Computes the house edge from a winning bet
        @param bet a potentially winning bet
    */
    function _computeRollEdge(Bet memory bet) internal view returns (uint256) {
        return _computeRollWin(bet) / 1000 * config_house_edge;
    }

    /**
        @dev Computes the total winnings of a bet MINUS house edge
        @param bet a potentially winning bet
    */
    function _computeRollWithEdge(Bet memory bet) internal view returns (uint256) {
        uint256 odds = uint256(bet.value) - 1;
        return ((bet.amount * (100-odds)) / odds + bet.amount) / 1000 * (1000 - config_house_edge);
    }

    /*function _extract(string memory entry) internal pure returns (uint256, uint256) {
        strings.slice memory sl = entry.toSlice();
        strings.slice memory delim = "\"".toSlice();
        string[] memory parts = new string[](4);
        for(uint i = 0; i < parts.length; i++) {
            parts[i] = sl.split(delim).toString();
        }

        return (_stringToUintNormalize(parts[1]), _stringToUintNormalize(parts[3]));
    }*/
    
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