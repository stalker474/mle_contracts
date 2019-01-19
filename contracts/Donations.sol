pragma solidity ^0.4.25;

import "../openzeppelin-solidity/contracts/math/SafeMath.sol";

contract ERC20Interface {
    function balanceOf(address _owner) external returns (uint256);
    function transfer(address _to, uint256 _value) external;
}

contract Donations {
    using SafeMath for uint256;

    struct Knight
    {
        address ethAddress;
        ///@dev amount in % of ETH and HORSE to distribute from this contract
        uint256 equity;
    }

    /// @dev list of all knights by name
    mapping(string => Knight) knights;

    /// @dev handle to access HORSE token contract to make transfers
    ERC20Interface constant horseToken = ERC20Interface(0x5B0751713b2527d7f002c0c4e2a37e1219610A6B);

    ///@dev true for HORSE, false for ETH
    mapping(bool => uint256) private _toDistribute;
    ///@dev true for HORSE, false for ETH
    mapping(bool => mapping(address => uint256)) private _balances;
    ///@dev used internally for computation
    mapping(string => uint256) private _due;

    /// @dev helpers to make code look better
    bool constant ETH = false;
    bool constant HORSE = true;
   
    /**
        @dev Initialize the contract with the correct knights and their equities and addresses
        All spoils are to be shared by Five Knights, the distribution of which is decided by God almighty
    */
    constructor() public {
        knights["Safir"].equity = 27;
        knights["Lucan"].equity = 27;
        knights["Lucan"].ethAddress = 0x445D779acfE04C717cc6B0071D3713D7E405Dc99;
        knights["Lancelot"].equity = 27;
        knights["Lancelot"].ethAddress = 0x5873d3875274753f6680a2256aCb02F2e42Be1A6;
        knights["Hoel"].equity = 11;
        knights["YwainTheBastard"].equity = 8;
    }
    
    /**
        @dev The empty fallback function allows for ETH payments on this contract
    */
    function () external payable {
       //fallback function just accept the funds
    }
    
    /**
        @dev Called by anyone willing to pay the fees for the distribution computation and withdrawal of HIS due
        This checks for changes in the amounts of ETH and HORSE owned by the contract and updates the balances
        of all knights acordingly
    */
    function withdraw() external {
        //update the balances of all knights
        _distribute(ETH);
        _distribute(HORSE);

        // check how much the caller is due of HORSE and ETH
        uint256 toSendHORSE = _balances[HORSE][msg.sender];
        uint256 toSendETH = _balances[ETH][msg.sender];

        //if the caller is due HORSE, send it to him
        if(toSendHORSE > 0) {
            _balances[HORSE][msg.sender] = 0;
            horseToken.transfer.gas(40000)(msg.sender,toSendHORSE);
        }

        //if the caller is due ETH, send it to him
        if(toSendETH > 0) {
            _balances[ETH][msg.sender] = 0;
            msg.sender.transfer(toSendETH);
        }
    }
    
    /**
        @dev Allows a knight to check the amount of ETH and HORSE he can withdraw
        !!! During withdraw call, the amount is updated before being sent to the knight, so these values may increase
        @return (ETH balance, HORSE balance)
    */
    function checkBalance() external view returns (uint256,uint256) {
        return (_balances[ETH][msg.sender],_balances[HORSE][msg.sender]);
    }

    /**
        @dev Updates the amounts of ETH and HORSE to distribute
        @param isHorse [false => ETH distribution, true => HORSE distribution]
    */
    function _update(bool isHorse) internal {
        //get either ETH or HORSE balance
        uint256 balance = isHorse ? horseToken.balanceOf.gas(40000)(address(this)) : address(this).balance;
        //if there is something on the contract, compute the difference between knight balances and the contract total amount
        if(balance > 0) {
            _toDistribute[isHorse] = balance
            .sub(_balances[isHorse][knights["Safir"].ethAddress])
            .sub(_balances[isHorse][knights["Lucan"].ethAddress])
            .sub(_balances[isHorse][knights["Lancelot"].ethAddress])
            .sub(_balances[isHorse][knights["YwainTheBastard"].ethAddress])
            .sub(_balances[isHorse][knights["Hoel"].ethAddress]);

            //if _toDistribute[isHorse] is 0, then there is nothing to update
        } else {
            //just to make sure, but can be removed
            _toDistribute[isHorse] = 0;
        }
    }
    
    /**
        @dev Handles distribution of non distributed ETH or HORSE
        @param isHorse [false => ETH distribution, true => HORSE distribution]
    */
    function _distribute(bool isHorse) private {
        //check the difference between current balances levels and the contracts levels
        //this will provide the _toDistribute amount
        _update(isHorse);
        //if the contract balance is more than knights balances combined, we need a distribution
        if(_toDistribute[isHorse] > 0) {
            //we divide the amount to distribute by 100 to know how much each % represents
            uint256 parts = _toDistribute[isHorse].div(100);
            //the due of each knight is the % value * equity (27 equity = 27 * 1% => 27% of the amount to distribute)
            _due["Safir"] = knights["Safir"].equity.mul(parts);
            _due["Lucan"] = knights["Lucan"].equity.mul(parts);
            _due["Lancelot"] = knights["Lancelot"].equity.mul(parts);
            _due["YwainTheBastard"] = knights["YwainTheBastard"].equity.mul(parts);
            //the 5th knight due is computed by substraction of the others to avoid dust error due to division
            _due["Hoel"] = _toDistribute[isHorse].sub(_due["Safir"].add(_due["Lucan"]).add(_due["Lancelot"]).add(_due["YwainTheBastard"]));

            //all balances are augmented by the computed due
            _balances[isHorse][knights["Safir"].ethAddress] = _balances[isHorse][knights["Safir"].ethAddress].add(_due["Safir"]);
            _balances[isHorse][knights["Lucan"].ethAddress] = _balances[isHorse][knights["Lucan"].ethAddress].add(_due["Lucan"]);
            _balances[isHorse][knights["Lancelot"].ethAddress] = _balances[isHorse][knights["Lancelot"].ethAddress].add(_due["Lancelot"]);
            _balances[isHorse][knights["YwainTheBastard"].ethAddress] = _balances[isHorse][knights["YwainTheBastard"].ethAddress].add(_due["YwainTheBastard"]);
            _balances[isHorse][knights["Hoel"].ethAddress] = _balances[isHorse][knights["Hoel"].ethAddress].add(_due["Hoel"]);
            
            //the amount to distribute is set to zero
            _toDistribute[isHorse] = 0;
        }
    }
}