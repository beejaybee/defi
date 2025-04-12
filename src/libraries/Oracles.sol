//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;


import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Oracle Lib
 * @author Bolaji Oyewo
 * @notice The library is used to check the chainlink Oracle for stale data
 * If a price is stale, the function will revert and render the DSCENGINE unsable - This is by design 
 * So if the chainlink network explodes and you have a lot of money locked in the protocol... Too bad
 * 
 */

library OracleLib {

    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed) 
    public 
    view 
    returns(uint80, int256, uint256, uint256, uint80) {

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;

        if (secondsSince > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);

    }
}