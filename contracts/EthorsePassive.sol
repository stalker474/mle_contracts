pragma solidity ^0.4.24;

import "../openzeppelin-solidity/contracts/math/SafeMath.sol";

contract EthorsePassive {
    using SafeMath for uint256;    
    
    event NewBet(address indexed user, uint256 amount, bytes32 pool);
    event Profit(bytes32 indexed pool, uint256 amount);
    event Withdraw(bytes32 indexed pool, address indexed user,  uint256 amount);

    struct BettingPool {
        uint256 poolBondsTotal;
        mapping(address => uint256) balanceOf;
        mapping(address => uint256) toWithdraw;
        uint256 etherPool;
        uint256 bondsWithdrawPool;
        uint256 etherWithdrawPool;
        uint256 withdrawPoolBondsTotal;
        uint256 investorCount;
        uint256 currentRacesCount;
    }
    
    mapping(bytes32 => BettingPool) common_pools;
    mapping(address => uint256) balanceOf;

    

    constructor() public {
    }
    
    /**
        @dev Create a passive bet
        @param maxBet Maximum bet PER COIN 0 => 0.01eth, 1 => 0.05 eth, 2 => 0.1 eth
        @param betOnLTC true if allow betting on ltc for every race
        @param betOnBTC true if allow betting on btc for every race
        @param betOnETH true if allow betting on eth for every race
        @param allRaces true if bet on all races, false for only 3 races a day
    */
    function autobet(uint8 maxBet, bool betOnLTC, bool betOnBTC, bool betOnETH, bool allRaces) external payable {
        require(maxBet <= 2, "Value must be 0, 1 or 2");
        require(betOnLTC || betOnBTC || betOnETH, "Must bet on at least one coin");

        //3%
        uint256 depositFee = msg.value.div(100).mul(3);
        uint256 toDeposit = msg.value.sub(depositFee);
        require(toDeposit >= 0.01 ether,"You dont have enough in your betting pool");
        
        bytes32 poolID = keccak256(abi.encodePacked(maxBet, betOnLTC, betOnBTC, betOnETH, allRaces));
       
        BettingPool storage pool = common_pools[poolID];
        pool.etherPool = pool.etherPool.add(toDeposit + depositFee);
        pool.investorCount = pool.investorCount.add(1);
        // mint the bonds and give them to the investor, he will also own a small part of his deposit fees
        _mintBonds(poolID, msg.sender, toDeposit);
        
        emit NewBet(msg.sender, toDeposit, poolID);
        emit Profit(poolID, depositFee);
    }

    /**
        @dev Asks for withdrawal from a pool.
        @param poolID ID of the pool from which to withdraw
    */
    function prepare_withdraw(bytes32 poolID) external {
        BettingPool storage pool = common_pools[poolID];
        require(pool.balanceOf[msg.sender] > 0, "The user has no active bonds in this pool");
        require(pool.toWithdraw[msg.sender] == 0, "You already have ETH to withdraw");
        // add user bonds to the withdraw pool
        pool.bondsWithdrawPool = pool.bondsWithdrawPool.add(pool.balanceOf[msg.sender]);
        // store the amount of bonds the user owns
        pool.toWithdraw[msg.sender] = pool.balanceOf[msg.sender];
        // remove the bonds from the active betting balance
        pool.balanceOf[msg.sender] = 0;
        // remove from investors count
        pool.investorCount = pool.investorCount.sub(1);
        // update the total bonds to withdraw
        pool.withdrawPoolBondsTotal = pool.withdrawPoolBondsTotal.add(pool.toWithdraw[msg.sender]);
    }

    /**
        @dev Called by anyone (preferably our server) to handle pending withdrawals inbetween races
        @param poolID ID of the pool from which to withdraw
    */
    function handleWithdrawals(bytes32 poolID) external {
        BettingPool storage pool = common_pools[poolID];
        //can't handle withdrawals if the pool is engaged in races
        require(pool.currentRacesCount == 0,"This pool is locked in races");
        //now handle withdrawals
        if(pool.bondsWithdrawPool > 0) {
            uint256 bondValue = pool.etherPool.div(pool.poolBondsTotal);
            //convert bonds to ether
            pool.etherWithdrawPool = pool.etherWithdrawPool.add(pool.bondsWithdrawPool.mul(bondValue));
            //remove withdrawn bonds from the total now that we have the bond value
            pool.poolBondsTotal = pool.poolBondsTotal.sub(pool.bondsWithdrawPool);
            //handle wei error and update the new ETH balance of the pool
            pool.etherPool = pool.etherPool >= pool.etherWithdrawPool? pool.etherPool.sub(pool.etherWithdrawPool) : 0;
            //empty the withdraw pool
            pool.bondsWithdrawPool = 0;
        }
    }

    /**
        @dev used to withdraw all ETH the user put into a pool
        @param poolID id of the pool you wish to withdraw from
    */
    function withdraw(bytes32 poolID) external {
        BettingPool storage pool = common_pools[poolID];
        require(pool.toWithdraw[msg.sender] > 0, "No bonds ready for withdrawal");
        
        //compute the amount of ETH this user owns from the withdrawable ETH pool
        uint256 ownsFromPool = pool.etherWithdrawPool.mul(pool.toWithdraw[msg.sender].div(pool.withdrawPoolBondsTotal));
        //remove from the bonds total pool
        pool.withdrawPoolBondsTotal = pool.withdrawPoolBondsTotal.sub(pool.toWithdraw[msg.sender]);
        //empty the withdrawable bonds credit
        pool.toWithdraw[msg.sender] = 0;
        //take into account small wei error
        uint256 toTransfer = pool.etherWithdrawPool >= ownsFromPool? ownsFromPool : pool.etherWithdrawPool;
        //update the withdrawable ETH pool
        pool.etherWithdrawPool = pool.etherWithdrawPool.sub(toTransfer);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(toTransfer);
        emit Withdraw(poolID, msg.sender, toTransfer);
    }

    /**
        @dev fallback function to accept donations (such as Ethorse 2.5%)
    */
    function () external payable {

    }

    function claim(bytes32 poolID) external {
        BettingPool storage pool = common_pools[poolID];
        //bla bla bla get your money back

        pool.currentRacesCount = pool.currentRacesCount.sub(1);
    }

    /**
        @dev Internal function to mint the right amount of bonds of a pool based on the bonds current value
        @param poolID a keccak key to identify a pool by its configuration
        @param investor address of the user putting ETH in the pool
        @param etherInvested amount of ETH the user is putting in the pool
    */
    function _mintBonds(bytes32 poolID, address investor, uint256 etherInvested) internal {
        BettingPool storage pool = common_pools[poolID];
        // bond value is the current pool divided by the total bonds amount
        uint256 bondValue = pool.etherPool.div(pool.poolBondsTotal);
        uint256 bondsToMint = etherInvested.div(1 ether).mul(bondValue);
        pool.balanceOf[investor] = pool.balanceOf[investor].add(bondsToMint);
        pool.poolBondsTotal = pool.poolBondsTotal.add(bondsToMint);
    }
}
