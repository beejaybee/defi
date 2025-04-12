// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call functions in the contract

pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { DscEngine } from "../../src/DscEngine.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";


contract Handler is StdInvariant, Test {

    DecentralizedStableCoin dsc;
    DscEngine dscEngine;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timeMintIsCalled;
    address[] usersWithCollateralDeposited; 
    mapping(address => uint256) public totalCollateralDeposited;

    uint256 MAX_DEPOSIIT_SIZE = type(uint96).max;  // max uint 96 value

    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public  btcUsdPriceFeed;

    constructor(DscEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsc = _dsc;
        dscEngine = _dscEngine;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();

        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]); 

        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
    }


    function mintCollateral(uint256 amount, uint256 addressSeed) public {

        if (usersWithCollateralDeposited.length == 0 ) {
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);

        uint256 maxDscToMint = (collateralValueInUsd / 2) - totalDscMinted; // you might hardcode if this fn doesn't exist
        if (maxDscToMint < 0) {
            return; // already maxed out
        }

        amount = bound(amount, 0, maxDscToMint);
        
        if (amount <= 0) {
            return;
        }

        vm.startPrank(sender);

        dscEngine.mintDsc(amount);

        vm.stopPrank();

        timeMintIsCalled++;
    }
    // redeemCollateral
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {

        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIIT_SIZE);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, amountCollateral);

        collateral.approve(address(dscEngine), amountCollateral);

        dscEngine.depositCollateral(address(collateral), amountCollateral);

        vm.stopPrank();

        totalCollateralDeposited[msg.sender] += amountCollateral;

        // Only push unique users
        bool isKnownUser = false;
        for (uint256 i = 0; i < usersWithCollateralDeposited.length; i++) {
            if (usersWithCollateralDeposited[i] == msg.sender) {
                isKnownUser = true;
                break;
            }
        }
        if (!isKnownUser) {
            usersWithCollateralDeposited.push(msg.sender);
        }

    } 


    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalance(address(collateral), msg.sender);

        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);

        if (amountCollateral == 0) {
            return;
        }
        vm.startPrank(msg.sender);

        dscEngine.redeemCollateral(address(collateral), amountCollateral);

        vm.stopPrank();
    }

    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);

    // }


    // Helper function

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns(ERC20Mock) {

        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}