//SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { DscEngine } from "src/DscEngine.sol";
import { DecentralizedStableCoin } from "src/DecentralizedStableCoin.sol";
import { DeployDsc } from "script/DeployDsc.s.sol";
import { HelperConfig } from "script/HelperConfig.s.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import { MockV3Aggregator } from "../mocks/MockV3Aggregator.sol";
import { MockMoreDebtDSC } from "../mocks/MockMoreDebtDSC.sol";

contract DscEngineTest is Test {

    DscEngine dscEngine;
    DecentralizedStableCoin dsc;
    DeployDsc deployer;
    HelperConfig config;

    address ethUsdPriceFeed;
    address weth;
    address btcUsdPriceFeed;
    address wbtc;
    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;


    address public USER = makeAddr("USER");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC_20_BALANCE = 10 ether;
    uint256 amountToMint = 100 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    

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

    function testUserBalanceDecreasesAfterDeposit() public depositedCollateral {
        uint256 userBalanceAfter = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalanceAfter, STARTING_ERC_20_BALANCE - AMOUNT_COLLATERAL);
    }

    

    ///////////////////////////////////////////
    //////   Test Mint DSC                 ///
    /////////////////////////////////////////

    function testRevertIfMintAmountIsZero() public {
        vm.startPrank(USER);

        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.mintDsc(0);

        vm.stopPrank();
    }

    

    function testRevertIfHealthFactorIsBroken() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));

        vm.expectRevert(abi.encodeWithSelector(DscEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDscSuccessfully() public depositedCollateral {
        vm.startPrank(USER);

        uint256 mintAmount = 100 ether;
        dscEngine.mintDsc(mintAmount);

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, mintAmount);

        (uint256 totalDscMinted, ) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, mintAmount);

        vm.stopPrank();
    }

    function testRevertIfMintFails() public depositedCollateral {
        // Simulate failure in mint function
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(DecentralizedStableCoin.mint.selector),
            abi.encode(false) // Return false to simulate mint failure
        );

        vm.startPrank(USER);

        uint256 mintAmount = 10 ether;

        vm.expectRevert(DscEngine.DSCEngine__MintFailed.selector);
        dscEngine.mintDsc(mintAmount);

        vm.stopPrank();
    }

    ////////////////////////////////////////////////
    ///// depositColatteralAndMintDsc Tests ///////
    //////////////////////////////////////////////


    function testRevertIfCollateralIsZeroAndMintAmountIsZero() public {
        vm.startPrank(USER);

        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateralAndMintDsc(weth, 0, 0);

        vm.stopPrank();
    }

    function testDepositCollateralSuccessfully() public {

        // Fetch latest price of ETH in USD
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        
        // Convert AMOUNT_COLLATERAL to USD value
        uint256 amountCollateralInUsd = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        // Approve WETH for deposit
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // Deposit collateral
        vm.startPrank(USER);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 1);
        vm.stopPrank();

        // Get the total collateral value in USD from the engine
        (, uint256 totalCollateralValueInUsd) = dscEngine.getAccountInformation(USER);

        // Check that the total collateral value matches the expected USD value
        assertEq(totalCollateralValueInUsd, amountCollateralInUsd, "Collateral deposit USD value mismatch");
    }


    function testMintDscSuccessfully() public {
        uint256 mintAmount = 100e18;

        // Approve WETH for deposit
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // Deposit collateral
        vm.startPrank(USER);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, mintAmount);
        vm.stopPrank();

    

        // Check that the USER has minted the correct amount of DSC
        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, mintAmount, "User DSC balance mismatch");

        // Check that the total DSC minted matches the expected mint amount
        (uint256 totalDscMinted, ) = dscEngine.getAccountInformation(USER);
        assertEq(totalDscMinted, mintAmount, "Total DSC minted mismatch");
    }

    function testRevertIfMintFailsInDepositCollateralAndMintDsc() public {
        uint256 mintAmount = 100e18;

        // Approve WETH for deposit
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        
        // Simulate failure in mint function BEFORE the first call
        vm.mockCall(
            address(dsc),
            abi.encodeWithSelector(DecentralizedStableCoin.mint.selector),
            abi.encode(false) // Return false to simulate mint failure
        );


        // Deposit collateral and Expect mint failure
        vm.startPrank(USER);

        vm.expectRevert(DscEngine.DSCEngine__MintFailed.selector);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, mintAmount);
        vm.stopPrank();
    }

    function testHealthFactorIsMaintained() public {
        uint256 amountDscToMint = 5e18;

        // Approve WETH for deposit
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // Deposit collateral and mint DSC
        vm.startPrank(USER);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDscToMint);
        vm.stopPrank();

        // Check health factor is above the threshold
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);
        assertGt(userHealthFactor, dscEngine.getMinHealthFactor(), "Health factor too low");
    }


    function testRevertIfHealthFactorIsBrokenIndepositAndMintDsc() public {

        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        uint256 amountDscToMint = (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        // Approve WETH for deposit
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.startPrank(USER);
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amountDscToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));

        // Expect revert if minting breaks health factor
        vm.expectRevert(abi.encodeWithSelector(DscEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountDscToMint);
        vm.stopPrank();
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


    function testRevertIfNotMoreThanZero() public {
        uint256 amount = 0;
        vm.prank(USER);

        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.checkMoreThanZero(amount);
    }


    ///////////////////////////////
    ///// BUrnDsc Tests     ///////
    ///////////////////////////////



    function testCanBurnDscSuccessfully() public {
        uint256 amountToBurn = 50 ether;

        // Approve WETH for DEPOSIT
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // User should now have DSC
        uint256 userDscBalanceBefore = dsc.balanceOf(USER);
        assertEq(userDscBalanceBefore, amountToMint, "User should have minted DSC");

         // Check collateral balance in dscEngine
        uint256 collateralBalance = dscEngine.getCollateralBalance(weth, USER);
        assertEq(collateralBalance, AMOUNT_COLLATERAL, "Collateral balance should match deposited amount");

        // Burn DSC
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountToBurn);
        dscEngine.burnDsc(amountToBurn);
        vm.stopPrank();

        // Check new balance
        uint256 userDscBalanceAfter = dsc.balanceOf(USER);
        assertEq(userDscBalanceAfter, userDscBalanceBefore - amountToBurn, "User DSC balance should decrease by burn amount");
    }

    function testRevertIfBurningMoreThanMinted() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();

        // Attempt to burn more than minted
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.burnDsc(amountToMint + 1 ether);
        vm.stopPrank();
    }

    /////////////////////////////////////////
    /////    RedeemCollateral Tests     ////
    ///////////////////////////////////////

    function testRevertIfRedeemCollateralAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        uint256 initialBalance = ERC20Mock(weth).balanceOf(USER);
        
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        
        uint256 finalBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(finalBalance, initialBalance + AMOUNT_COLLATERAL);
    }



    //////////////////////////////////////////////
    /////    RedeemCollateralForDsc Tests     ////
    /////////////////////////////////////////////

    
    function testRevertIfCollateralIsZeroOrDscIsZero() public depositedCollateral {
        AMOUNT_COLLATERAL = 0;
        uint256 amountDscToBurn = 0;
        
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountDscToBurn);
        vm.expectRevert(DscEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountDscToBurn);
        vm.stopPrank();
    }

    function testRevertIfBurningDscMoreThanMinted() public depositedCollateral {
        uint256 amountDscToBurn = amountToMint + 1 ether; // More than minted
        AMOUNT_COLLATERAL = 1 ether;
        
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amountDscToBurn);
        vm.expectRevert();
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountDscToBurn);
        vm.stopPrank();
    }

    function testCanRedeemCollateralForDscSuccessfully() public depositedCollateral {
        uint256 amountDscToBurn = 50 ether;

        vm.startPrank(USER);

        // Debugging logs
        console.log("User DSC Balance Before Minting: ", dsc.balanceOf(USER));

        // Mint DSC before trying to burn it
        dscEngine.mintDsc(amountDscToBurn);

        // Update amountToMint to reflect the actual amount minted
        amountToMint = amountDscToBurn;

        // Log balances after minting
        console.log("User DSC Balance After Minting: ", dsc.balanceOf(USER));

        // Ensure USER has enough DSC to burn
        require(dsc.balanceOf(USER) >= amountDscToBurn, "Not enough DSC to burn");

        dsc.approve(address(dscEngine), amountDscToBurn);
        dscEngine.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, amountDscToBurn);
        
        vm.stopPrank();

        uint256 userDscBalanceAfter = dsc.balanceOf(USER);
        uint256 collateralBalanceAfter = ERC20Mock(weth).balanceOf(USER);

        // Debugging logs
        console.log("User DSC Balance After Burn: ", userDscBalanceAfter);
        console.log("User Collateral Balance After Redeem: ", collateralBalanceAfter);

        assertEq(userDscBalanceAfter, amountToMint - amountDscToBurn);
        assertEq(collateralBalanceAfter, STARTING_ERC_20_BALANCE - AMOUNT_COLLATERAL + AMOUNT_COLLATERAL);
    }


    /////////////////////////////////////
    /////   Liquidation Tests     //////
    ////////////////////////////////////


    // This test needs it's own setup
    // function testMustImproveHealthFactorOnLiquidation() public {
    //     // Arrange - Setup
    //     MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
    //     tokenAddresses = [weth];
    //     priceFeedAddresses = [ethUsdPriceFeed];

    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     DscEngine mockDsce = new DscEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
    //     mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
    //     vm.stopPrank();

    //     // Arrange - Liquidator
    //     uint256 debtToCover = 10 ether;
    //     collateralToCover = 1 ether;
    //     ERC20Mock(weth).mint(liquidator, collateralToCover);
        
    //     // Mint DSC to liquidator using the correct caller (mockDsce as owner)
    //     vm.prank(address(mockDsce)); // Ensuring owner calls mint
    //     mockDsc.mint(liquidator, debtToCover);

    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
    //     mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    //     mockDsc.approve(address(mockDsce), debtToCover);
    //     // Act
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

    //     // Ensure the price update is correctly applied
    //     int256 latestPrice = MockV3Aggregator(ethUsdPriceFeed).latestAnswer();
    //     require(latestPrice == ethUsdUpdatedPrice, "Price feed update failed"); 

    //     // Check borrower's health factor
    //     uint256 healthFactor = mockDsce.getHealthFactor(USER);
    //     console.log("Borrower Health Factor After Price Drop: ", healthFactor);

    //     // Ensure health factor is below the threshold
    //     require(healthFactor < mockDsce.getMinHealthFactor(), "Health factor is not broken");
        
    //     // Act/Assert
    //     vm.expectRevert(DscEngine.DSCEngine__HealthFactorNotImproved.selector);
    //     mockDsce.liquidate(weth, USER, debtToCover);
    //     vm.stopPrank();
    // }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);

        vm.expectRevert(DscEngine.DSCEngine__HealthFactorIsNotBroken.selector);
        dscEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) * dscEngine.getLiquidationBonus() / dscEngine.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the USER lost
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) * dscEngine.getLiquidationBonus() / dscEngine.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dscEngine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = dscEngine.getAccountInformation(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dscEngine.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dscEngine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dscEngine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(USER);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    // function testGetCollateralBalanceOfUser() public {
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    //     uint256 collateralBalance = dscEngine.getCollateralBalance(USER, weth);
    //     assertEq(collateralBalance, AMOUNT_COLLATERAL);
    // }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 collateralValue = dscEngine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dscEngine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }
    
}