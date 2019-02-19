pragma solidity ^0.5.2;

import "../ethereum-api/oraclizeAPI_0.5.sol";
import "../openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "../solidity-stringutils/src/strings.sol";

contract EthorseDerby is usingOraclize, Pausable, Ownable {

    using SafeMath for uint256;
    using strings for *;
	uint256 constant PRECISION = 1000000;

    /// @dev events
    event NewRace(uint256 race_id);
    event RaceEnded(uint256 race_id, bool btc_won, bool ltc_won, bool eth_won);
    event RaceRefunded(uint256 race_id);
    event BetClaimed(uint256 race_id, address player, uint256 amount);
    event BetPlaced(uint256 race_id, uint256 amount_btc, uint256 amount_ltc, uint256 amount_eth);
    event OraclizeError(uint256 value);


    // config
    /// @dev time before a started roll has to reach the DONE state before it can be refunded
    uint256 public config_refund_delay = 2 days;
		/// @dev minimal allowed duration
    uint256 public config_min_duration = 5 minutes;
	/// @dev maximal allowed duration
    uint256 public config_max_duration = 1 days;
    /// @dev gas limit for price callbacks
    uint256 public config_gas_limit = 200000;
    // @dev gas price for transactions
    uint256 public config_gasprice = 20000000000 wei;
    /// @dev house edge
    uint256 public config_house_edge = 7500000; //7.5%
    /// @dev address to which send the house cut on withdrawal
    address payable config_cut_address = 0xA54741f7fE21689B59bD7eAcBf3A2947cd3f3BD4;
    /// @dev possible states of a race
    enum State {READY, WAITING_QUERY1, WAITING_QUERY2, DONE, REFUND}

    /// @dev oraclize queries for ETH,BTC and LTC with encrypted api key for cryptocompare
    string constant public query_string = "[URL] json(https://min-api.cryptocompare.com/data/pricemulti?fsyms=ETH,BTC,LTC&tsyms=USD&extraParams=EthorseDerby&sign=true&api_key=${[decrypt] BB+VUXuu1fOGP2zlf5DI7lO6QJkY+Q+NH3g+thd0G2hcpRAZyOussOYdZg8tbs8usk/BCmDug525UuF++FKxuIqfLA0A/JdvWnUHrZnM194wUH1UQc8VlQ8404iHc24twpY1R7R7I5RLVsNamEZftxjRXBpWqCU6j9BrJqlPGgbUbyZw4PSIiPW9ErAYJwccCg==}).[ETH,BTC,LTC].USD";

    /// @dev current roll id
    uint256 public current_race = 0;
    /// @dev total amount of collected eth by the house
    uint256 public house;

    /// @dev describes a user bet
    struct Bet {
        //amount of wagered ETH in Wei
        uint256 amount_eth;
		uint256 amount_btc;
		uint256 amount_ltc;
    }

    /// @dev describes a roll
    struct Race {
        // oraclize query ids
        bytes32 query_price_start;
		bytes32 query_price_end;
        // query results
        uint256 result_price_start_ETH;
		uint256 result_price_start_BTC;
		uint256 result_price_start_LTC;
		uint256 result_price_end_ETH;
		uint256 result_price_end_BTC;
		uint256 result_price_end_LTC;

        uint256 race_duration;
		uint256 min_bet;
		uint256 start_time;
		uint256 betting_duration;
        uint256 btc_pool;
		uint256 ltc_pool;
    	uint256 eth_pool;

		uint256 winners_total;
        State state;
		bool btc_won;
		bool ltc_won;
		bool eth_won;
        // mapping bettors to their bets on this roll
        mapping(address => Bet) bets;
    }

    mapping(uint256 => Race) public races;
    mapping(bytes32 => uint256) internal _query_to_race;
    /// @dev mapping to prevent processing twice the same query
    mapping(bytes32 => bool) internal _processed;
    /// @dev internal wallet
    mapping(address => uint256) public balanceOf;

    /**
        @dev init the contract
    */
    constructor() public
    Pausable()
    Ownable() {
		//TLSNotary proof for URLs
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
    }

    function newRace(uint256 race_duration, uint256 betting_duration, uint256 start_time, uint256 min_bet) public payable
    whenNotPaused() {
		require(duration >= config_min_duration && duration <= config_max_duration,"Invalid duration");
		require(start_time > block.timestamp, "Races must start in the future");
		require(min_bet > 0, "Must set a greater minimal bet");
		require(betting_duration > 1 minutes, "Betting duration is too short");

        //compute oraclize fees
        uint256 call_price = oraclize_getPrice("URL", config_gas_limit) * 2; //2 calls

        if(call_price >= msg.value) {
            //the caller didnt send enough for oraclize fees, just push an event and display the desired price
            emit OraclizeError(call_price);
        } else {
            //lets race!
            Race storage race = races[current_race];
			
			//save the oraclize query indices for proof 
			uint256 starts_in = start_time.add(betting_duration).sub(block.timestamp);
			uint256 ends_in = start_time.add(betting_duration).sub(block.timestamp).add(race_duration);
			race.query_price_start = oraclize_query(starts_in, "nested", query_string, config_gas_limit);
			race.query_price_end = oraclize_query(ends_in, "nested", query_string, config_gas_limit);
			
			race.state = State.WAITING_QUERY1;
			race.race_duration = race_duration;
			race.min_bet = min_bet;
			race.betting_duration = betting_duration;

			//save mappings to find the right race number associated with this query
			_query_to_race[race.query_price_start] = current_race;
			_query_to_race[race.query_price_end] = current_race;

			emit NewRace(current_race);
			_prepareNextRace();
        }
    }

    /**
        @dev Allows to place a bet on a specific race
        @param race_id : race number
        @param is_up : true if the expected price change is positive, false overwise
    */
    function placeBet(uint256 race_id, uint256 eth_bet, uint256 btc_bet, uint256 ltc_bet) external payable {
		uint256 total_bet = eth_bet.add(btc_bet).add(ltc_bet);
		uint256 betting_ends = race.start_time.add(race.betting_duration);
		uint256 house_edge = total_bet.mul(PRECISION).div(config_house_edge);
		house = house.add(house_edge);

		Race storage race = races[race_id];
		require(race.State == WAITING_QUERY1, "Invalid race state");
		require(block.timestamp >= race.start_time, "Not in betting phase");
		require(block.timestamp <= betting_ends, "Not in betting phase");
		require(msg.value == total_bet.add(house_edge), "Invalid payment");
		require(total_bet >= race.min_bet, "Invalid bet");

		Bet storage bet = race.bets[msg.sender];
		bet.amount_btc = bet.amount_btc.add(btc_bet);
		bet.amount_ltc = bet.amount_ltc.add(ltc_bet);
		bet.amount_eth = bet.amount_eth.add(eth_bet);

		race.btc_pool = race.btc_pool.add(btc_bet);
		race.ltc_pool = race.ltc_pool.add(ltc_bet);
		race.eth_pool = race.eth_pool.add(eth_bet);

		emit BetPlaced(race_id, btc_bet, ltc_bet, eth_bet);
    }

    /**
        @dev Allows to claim the winnings from a race
        @param race_id Race number of the race to claim from
    */
    function claim(uint256 race_id) external {
        Race storage race = races[race_id]; 
        Bet storage bet = race.bets[msg.sender];
		uint256 total_bet = bet.amount_btc.add(bet.amount_ltc).add(bet.amount_eth);

        //handle refunding if contract isnt in the DONE or REFUND state after the refund delay is passed
        //also prevent refunding not started rolls
        if(roll.state != State.DONE && roll.state != State.REFUND) {
            //allow refund after the delay has passed
			uint256 refund_time = race.start_time.add(race.betting_duration).add(config_refund_delay);
            if(block.timestamp >= refund_time) {
                race.state = State.REFUND;
            }
        }

		require(race.state == State.REFUND || race.state == State.DONE,"Cant claim from this race");
 
        //handle payments from refunded rolls
        if(race.state == State.REFUND) {
            if(total_bet) {
				msg.sender.transfer(total_bet);
				//delete the bet from the bets mapping of this roll
            	delete(race.bets[msg.sender]);
			}
        } else {
			uint256 wagered_winners_total = 0;
			
			if(race.btc_won) {
				wagered_winners_total = wagered_winners_total.add(bet.amount_btc);
			}
			if(race.ltc_won) {
				wagered_winners_total = wagered_winners_total.add(bet.amount_ltc);
			}
			if(race.eth_won) {
				wagered_winners_total = wagered_winners_total.add(bet.amount_eth);
			}
			
			uint256 to_pay = race.total_pool.mul(PRECISION).div(race.winners_total).mul(wagered_winners_total);
			msg.sender.transfer(to_pay);
            emit BetClaimed(round,msg.sender,to_pay);
        }
    }

    // the callback function is called by Oraclize when the result is ready
    // the oraclize_randomDS_proofVerify modifier prevents an invalid proof to execute this function code:
    // the proof validity is fully verified on-chain
    function __callback(bytes32 _queryId, string memory _result, bytes memory _proof) public
    { 
        require (msg.sender == oraclize_cbAddress(), "auth failed");
        require(!_processed[_queryId], "Query has already been processed!");
        _processed[_queryId] = true;


		//fetch the roll associated with this query
		uint256 roll_id = _query_to_race[_queryId];
		require(roll_id > 0, "Invalid _queryId");
		Race storage race = races[race_id];
		//identify which query is this
		if(_queryId == race.query_price_start) {
			(race.result_price_start_BTC,race.result_price_start_LTC,race.result_price_start_ETH) = _extractPrices(_result);
			// increment state to show we're waiting for the next queries now
			race.state = State(uint(race.state) + 1);
		} else if(_queryId == race.query_price_end) {
			(race.result_price_end_BTC,race.result_price_end_LTC,race.result_price_end_ETH) = _extractPrices(_result);
			// increment state to show we're waiting for the next queries now
			race.state = State(uint(race.state) + 1);
		} else {
			//fatal error
			roll.state = State.REFUND;
			emit RaceRefunded(race_id);
		}
		//if the race state has been incremented enough (2 times), we've finished
		if(race.state == State.DONE) {
			int256 btc_delta = int256(race.result_price_end_BTC) - int256(race.result_price_start_BTC);
			int256 ltc_delta = int256(race.result_price_end_LTC) - int256(race.result_price_start_LTC);
			int256 eth_delta = int256(race.result_price_end_ETH) - int256(race.result_price_start_ETH);
            
			race.btc_won = btc_delta >= ltc_delta && btc_delta >= eth_delta;
			race.ltc_won = ltc_delta >= btc_delta && ltc_delta >= eth_delta;
			race.eth_won = eth_delta >= ltc_delta && eth_delta >= btw_delta;

			race.total_pool = race.btc_pool.add(race.ltc_pool).add(race.eth_pool);

			if(race.btc_won) {
				race.winners_total = race.winners_total.add(race.btc_pool);
			}
			if(race.ltc_won) {
				race.winners_total = race.winners_total.add(race.ltc_pool);
			}
			if(race.eth_won) {
				race.winners_total = race.winners_total.add(race.eth_pool);
			}
			emit RaceEnded(race_id, race.btc_won, race.ltc_won, race.eth_won);
		}
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
        @dev Sets the gas price to be used by oraclize
        @param new_gasprice Gas in wei
    */
    function setGasPrice(uint256 new_gasprice) external
    onlyOwner() {
        config_gasprice = new_gasprice;
        oraclize_setCustomGasPrice(config_gasprice);
    }

	/**
        @dev Sets the maximum allowed race duration
        @param new_duration duration in seconds
    */
    function setMaxDuration(uint256 new_duration) external
    onlyOwner() {
        config_max_duration = new_duration;
    }

	/**
        @dev Sets the minimum allowed race duration
        @param new_duration duration in seconds
    */
    function setMinDuration(uint256 new_duration) external
    onlyOwner() {
        config_min_duration = new_duration;
    }

	/**
        @dev Sets the delay to wait before a race gets refunded
        @param new_delay duration in seconds
    */
    function setRefundDelay(uint256 new_delay) external
    onlyOwner() {
        config_refund_delay = new_delay;
    }

    function _prepareNextRace() internal {
		//increment race id for the next one
		current_race = current_race.add(1);
        Race storage race = races[current_race].state = State.READY;
	}

    function _extractPrices(string memory entry) internal pure returns (uint256, uint256, uint256) {
        strings.slice memory sl = entry.toSlice();
        strings.slice memory delim = "\"".toSlice();
        string[] memory parts = new string[](4);
        for(uint i = 0; i < parts.length; i++) {
            parts[i] = sl.split(delim).toString();
        }
        return (_stringToUintNormalize(parts[1]), _stringToUintNormalize(parts[3]), _stringToUintNormalize(parts[5]));
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