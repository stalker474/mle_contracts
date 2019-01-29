pragma solidity ^0.5.2;

import "../ethereum-api/oraclizeAPI_0.5.sol";
import "../openzeppelin-solidity/contracts/math/SafeMath.sol";
import "../openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "../openzeppelin-solidity/contracts/ownership/Ownable.sol";
//import "../solidity-stringutils/src/strings.sol";

contract PriceRoll is usingOraclize, Pausable, Ownable {

    using SafeMath for uint256;
//    using strings for *;

    // events
    event Rolling(uint256 round);
    event NewRoll(uint256 round);
    event RollEnded(uint256 round, uint8 value, uint256 start_price, uint256 end_price);
    event RollRefunded(uint256 round);
    event RollClaimed(uint256 round, address indexed player);
    event BetPlaced(uint256 round, address indexed player, uint256 amount, uint8 expected_value, bool is_up);
    event OraclizeError(uint256 value);

    // config
    uint256 public config_roll_cooldown = 1 minutes;
    uint256 public config_refund_delay = 50 minutes;
    uint256 public config_gas_limit = 300000;
    uint256 public config_random_gas_limit = 300000;
    uint256 public config_min_bet = 0.02 ether;
    uint256 public config_house_edge = 20; //2.0%
    uint256 public config_house_cut = 50; //5.0%
    uint256 public config_bonus_mult = 150; //15%
    uint256 public config_pricecheck_delay = 1 minutes;
    address payable config_cut_address = 0xA54741f7fE21689B59bD7eAcBf3A2947cd3f3BD4;

    // helpers
    enum State {READY, WAITING_QUERY1, WAITING_QUERY2, WAITING_QUERY3, DONE, REFUND}
    enum CoinRotation {ETHEREUM, BITCOIN, LITECOIN}
    uint8 constant coin_count = 3;

    string constant public query_stringETH = "json(https://min-api.cryptocompare.com/data/price?fsym=ETH&tsyms=USD&extraParams=PriceRoll&sign=true).USD";
    string constant public query_stringBTC = "json(https://min-api.cryptocompare.com/data/price?fsym=BTC&tsyms=USD&extraParams=PriceRoll&sign=true).USD";
    string constant public query_stringLTC = "json(https://min-api.cryptocompare.com/data/price?fsym=LTC&tsyms=USD&extraParams=PriceRoll&sign=true).USD";

    // stat values
    uint256 public current_roll = 0;
    uint256 public latest_roll = 0;
    CoinRotation public current_coin = CoinRotation.ETHEREUM;
    uint256 public house;

    struct Bet {
        uint256 amount;
        uint8 value;
        bool is_up;
    }

    struct Roll {
        bytes32 query_rng;
        bytes32 query_price1;
        bytes32 query_price2;
        uint256 result_price1;
        uint256 result_price2;
        uint256 result_timestamp1;
        uint256 result_timestamp2;
        uint256 timestamp;
        uint256 pool;
        State state;
        CoinRotation coin;
        uint8 result_rng;
        bool is_up;
        mapping(address => Bet) bets;
    }

    mapping(uint256 => Roll) public rolls;
    mapping(bytes32 => uint256) internal _query_to_roll;
    mapping(bytes32 => bool) internal _processed;
    mapping(address => uint256) public balanceOf;


    constructor() public
    Pausable()
    Ownable() {
        _generateRoll();
    }

    function newRoll() external payable
    whenNotPaused() {
        require(latest_roll + config_roll_cooldown <= block.timestamp, "roll is cooling down");
        uint256 call_price = _checkPrice();
        if(call_price > msg.value) {
            emit OraclizeError(call_price);
        } else {
            Roll storage roll = rolls[current_roll]; 
        
            string memory query;
            if(current_coin == CoinRotation.ETHEREUM) {
                query = query_stringETH;
            } else if(current_coin == CoinRotation.BITCOIN) {
                query = query_stringBTC;
            } else {
                query = query_stringLTC;
            }

            oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
            roll.query_price1 = oraclize_query(0, "URL", query, config_gas_limit);
            roll.query_price2 = oraclize_query(config_pricecheck_delay, "URL", query, config_gas_limit);
            //only ledger proof for random source
            oraclize_setProof(proofType_Ledger);
            roll.query_rng = oraclize_newRandomDSQuery(0, 1, config_random_gas_limit);

            
            //maybe in the future send the rest back if some is left
            
            roll.timestamp = block.timestamp;
            roll.state = State.WAITING_QUERY1;
            roll.coin = current_coin;

            _query_to_roll[roll.query_rng] = current_roll;
            _query_to_roll[roll.query_price1] = current_roll;
            _query_to_roll[roll.query_price2] = current_roll;

            emit Rolling(current_roll);

            _generateRoll();
        }
    }

    function betFromInternalWallet(uint256 amount, uint8 expected_value, bool is_up) public 
    whenNotPaused() {
        require(balanceOf[msg.sender] >= amount, "Not enough to bet the specified amount");
        require(expected_value > 1 && expected_value < 100,"Expected value must be in the range of 2 to 99");

        Roll storage roll = rolls[current_roll]; 
        Bet storage bet = roll.bets[msg.sender];
        require(bet.amount == 0, "Already placed a bet");

        bet.amount = amount;
        bet.value = expected_value;
        bet.is_up = is_up;

        roll.pool = roll.pool.add(bet.amount);

        balanceOf[msg.sender] = balanceOf[msg.sender].sub(amount);

        emit BetPlaced(current_roll, msg.sender, amount, expected_value, is_up);
    }

    function placeBet(uint8 expected_value, bool is_up) external payable {
        //add to internal wallet 
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
        betFromInternalWallet(msg.value, expected_value, is_up);
    }

    function withdrawWallet() external
    {
        uint256 balance = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        msg.sender.transfer(balance);
    }

    function creditWallet() external payable
    {
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    }

    function claim(uint256 round) external {
        Roll storage roll = rolls[round]; 
        Bet storage bet = roll.bets[msg.sender];
        require(bet.value > 0,"not a bettor");

        if(roll.state != State.DONE && roll.state != State.REFUND && roll.state != State.READY) {
            bool forced_refund = roll.timestamp + config_refund_delay < now;
            if(forced_refund) {
                roll.state = State.REFUND;
            }
        }
        
        if(roll.state == State.REFUND) {
            require(bet.amount > 0, "Already refunded");
            balanceOf[msg.sender] = balanceOf[msg.sender].add(bet.amount);
            delete(roll.bets[msg.sender]);
        } else {
            bool guessed_random = bet.value > roll.result_rng;
            bool guessed_pricemov = bet.is_up == roll.is_up; 

            uint256 to_pay = 0;

            require(guessed_random || guessed_pricemov, "No winnings to claim");
            uint256 realBet = bet.amount.mul(uint256(1000).sub(config_house_cut).div(1000));
            if(guessed_random) {
                uint256 win = (((realBet * (101/bet.value)) + realBet));
                uint256 edge = win.mul(config_house_edge).div(1000);
                to_pay = to_pay.add(win.sub(edge));
            }
            if(guessed_pricemov) {
                uint256 bonus = realBet.mul(config_bonus_mult).div(1000);
                to_pay = to_pay.add(bonus);
            }
            balanceOf[msg.sender] = balanceOf[msg.sender].add(to_pay);
            emit RollClaimed(round,msg.sender);
        }
    }

    function () external payable {
        //used for provisionning
    }

    //only test!!!!!!!!
    function destroy() external
    onlyOwner() {
        selfdestruct(msg.sender);
    }

    // the callback function is called by Oraclize when the result is ready
    // the oraclize_randomDS_proofVerify modifier prevents an invalid proof to execute this function code:
    // the proof validity is fully verified on-chain
    function __callback(bytes32 _queryId, string memory _result, bytes memory _proof) public
    { 
        require (msg.sender == oraclize_cbAddress(), "auth failed");
        require(!_processed[_queryId], "Query has already been processed!");
        _processed[_queryId] = true;

        uint256 roll_id = _query_to_roll[_queryId];
        require(roll_id > 0, "Invalid _queryId");
        Roll storage roll = rolls[roll_id];

        if(_queryId == roll.query_rng) {

            if (oraclize_randomDS_proofVerify__returnCode(_queryId, _result, _proof) != 0) {
                // the proof verification has failed
                roll.state = State.REFUND;
                emit RollRefunded(roll_id);
            } else {

                uint randomNumber = uint(keccak256(bytes(_result))) % 100 + 1;
                roll.result_rng = uint8(randomNumber);

                roll.state = State(uint(roll.state) + 1);
            }
        } else if(_queryId == roll.query_price1) {
            //(roll.result_price1, roll.result_timestamp1) = _extract(_result);
            roll.result_price1 = _stringToUintNormalize(_result);
            roll.state = State(uint(roll.state) + 1);
        } else if(_queryId == roll.query_price2) {
            roll.result_price2 = _stringToUintNormalize(_result);
            //(roll.result_price2, roll.result_timestamp2) = _extract(_result);
            roll.state = State(uint(roll.state) + 1);
        } else {

            //fatal error
            roll.state = State.REFUND;
            emit RollRefunded(roll_id);
        }

        if(roll.state == State.DONE) {
            //check price change
            roll.is_up = roll.result_price1 < roll.result_price2;
            
            //take commission etc...
            uint256 commission = roll.pool.mul(config_house_cut).div(1000);
            house = house.add(commission);

            emit RollEnded(roll_id, roll.result_rng, roll.result_price1, roll.result_price2);
        }
    }

    function withdrawHouse() external
    onlyOwner() {
        uint256 toTransfer = house;
        house = 0;
        msg.sender.transfer(toTransfer);
    }

    function setHouseEdge(uint256 new_edge) external
    onlyOwner() {
        require(new_edge <= 500,"max 50%");
        config_house_edge = new_edge;
    }

    function setBonus(uint256 new_bonus) external
    onlyOwner() {
        require(new_bonus <= 500,"max 50%");
        config_bonus_mult = new_bonus;
    }

    function setCutDestination(address payable new_desination) external
    onlyOwner() {
        config_cut_address = new_desination;
    }

    function setCooldown(uint256 new_cooldown) external
    onlyOwner() {
        require(new_cooldown >= 1 minutes,"Minimum is 1 minute");
        config_roll_cooldown = new_cooldown;
    }

    function setMinBet(uint256 new_minbet) external
    onlyOwner() {
        require(new_minbet > 0, "Must be greater than zero");
        config_min_bet = new_minbet;
    }

    function setGasLimit(uint256 new_gaslimit) external
    onlyOwner() {
        config_gas_limit = new_gaslimit;
    }

    function setRandomGasLimit(uint256 new_gaslimit) external
    onlyOwner() {
        config_random_gas_limit = new_gaslimit;
    }

    function setPriceCheckDelay(uint256 new_delay) external
    onlyOwner() {
        config_pricecheck_delay = new_delay;
    }

    function _generateRoll() internal {
        current_roll = current_roll.add(1);
        current_coin = CoinRotation((uint(current_coin)+1)%coin_count);
        latest_roll = block.timestamp;

        emit NewRoll(current_roll);
    }

    function _checkPrice() internal returns (uint256) {
        //TLSNotary proof for URLs
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
        uint256 call_price = oraclize_getPrice("URL", config_gas_limit) * 2; //2 calls
        oraclize_setProof(proofType_Ledger);
        return call_price.add(oraclize_getPrice("Random", config_random_gas_limit)); //1 call
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