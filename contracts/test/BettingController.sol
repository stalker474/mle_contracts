pragma solidity ^0.5.2;

import "./Betting.sol";

contract BettingController {
    address public owner;
    Betting public race;

    constructor() public {
        owner = msg.sender;

        race = new Betting();
    }
}