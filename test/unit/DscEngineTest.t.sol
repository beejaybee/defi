//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { DscEngine } from "src/DscEngine.sol";
import { DecentralizedStableCoin } from "src/DecentralizedStableCoin.sol";
import { DeployDsc } from "script/DeployDsc.s.sol";
import { HelperConfig } from "script/HelperConfig.s.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract DscEngineTest is Test {

    DscEngine dscEngine;
    DecentralizedStableCoin dsc;
    DeployDsc deployer;
    HelperConfig config;

    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC_20_BALANCE = 10 ether;

    function setUp() external {
        deployer = new DeployDsc();
        (dsc, dscEngine, config) = deployer.run();

        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC_20_BALANCE);
    }



    //////////////////////////
    /// Test Price Feeds ////
    /////////////////////////


    function testUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 extpectedUsd = 30000e18;

        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        
        assertEq(extpectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedAmount = 0.05 ether;

        uint256 actualAmount = dscEngine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedAmount, actualAmount);
    }


    ////////////////////////////////////
    /// Test deposit collateral     ////
    ///////////////////////////////////

    function testRevertIfCollateralIsZero() public {
        vm.prank(USER);

        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);

        dscEngine.depositCollateral(weth, 0);

        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("Ran", "RAN", USER, AMOUNT_COLLATERAL);

        vm.startPrank(USER);

        vm.expectRevert(DscEngine.DSCEngine__TokenNotAllowed.selector);

        dscEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDcsMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(expectedTotalDscMinted, totalDcsMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }



    ///////////////////////////////
    ///// Constructor Tests ///////
    ///////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIftokenLengthDoesntMatchPriceFeedLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        tokenAddresses.push(wbtc);


        vm.expectRevert(DscEngine.DSCEngine__TokenAddressLengthAndPriceFeedLengthMustBeSameLength.selector);
        new DscEngine(tokenAddresses, priceFeedAddresses, address(dsc));

    }

    

}