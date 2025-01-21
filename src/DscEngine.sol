// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions



// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Bolaji Oyewo
 * The system is designed as minimal as possible to maintain 1 token == $1 peg
 * The Stable coins has the properties
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI, If DAI had no gorvernance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC should always be "over collaterized", at no point should the value of all collateral <= the
 * value of our DSC
 *
 * @notice This contract is the core of the DSC system. it handles all the logic for minting and redeeming
 * DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS (DAI) system.
 */
contract DscEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;
    ////////////////////////////////////////////
    //               Errors                   //
    ////////////////////////////////////////////

    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressLengthAndPriceFeedLengthMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__InvalidPrice();
    error DSCEngine__HealthFactorIsNotBroken();
    error DSCEngine__HealthFactorNotImproved();

    ////////////////////////////////////////////
    //         State Variables                //
    ////////////////////////////////////////////


    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; // userToTokenToCollateral
    mapping(address user => uint256 amountOfDscMinted) private s_DscMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////////////////////////////////
    //                  EVENTS                //
    ////////////////////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address indexed tokenCollateral, uint256 amount);

    ////////////////////////////////////////////
    //               MODIFIERS                //
    ////////////////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    ////////////////////////////////////////////
    //               Functions                //
    ////////////////////////////////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feed
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressLengthAndPriceFeedLengthMustBeSameLength();
        }
        // for example, ETH/USD, BTC/USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////////////////////
    //      External Functions                //
    ////////////////////////////////////////////

    /* 
     * @param tokenCollateralAddress The address of the collateral to be deposited. (ETH, BTC)
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of Decentralized stable coin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction 
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral, 
        uint256 amountDscToMint
        ) external nonReentrant 
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @param tokenCollateralAddress The address of the collateral to be deposited. (ETH, BTC)
     * @param amountCollateral The amount of collateral to be deposited
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // deposit collateral

        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        IERC20(tokenCollateralAddress).safeTransferFrom(msg.sender, address(this), amountCollateral);
    }

    /*
     * @param tokenCollateralAddress The address of the collateral to be redeemed. (ETH, BTC)
     * @param amountCollateral The amount of collateral to be redeemed
     * @param amountDscToBurn The amount of Decentralized stable coin to burn
     * This function will burn DSC and redeem collateral in one transaction
     */

    function redeemCollateralForDsc( address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // In order to redeem collateral
    // 1. health factor must be over 1 after collateral pulled
    // CEI Check effect interaction
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // redeem collateral
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        // check if health factor is broken
        _revertIfHealthFactorIsBroken(msg.sender);

        
    }
    /*
     * @notice follows CEI
     * @param amountDscToMint The amount of Decentralized stable coin to mint
     * @notice they must have more collateral value than the minimum threshold
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        // check if collateral value is greater than DSC amount. Price feed value
        s_DscMinted[msg.sender] += amountDscToMint;

        // check if health factor is broken
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (!minted) {
            revert DSCEngine__MintFailed();
        }

    }

    function burnDsc(uint256 amount) public moreThanZero(amount){
        _burnDsc(amount, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }


    // If someone is almost collateralized, we will pay you to liqiudate them

    /**
     * @notice This function will liquidate a user if their health factor is below 1
     * @param collateral The address of the ERC20 collateral to be liquidated
     * @param user The address of the user who has broken the health factor, Their Health factor is below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of debt of DCS you want to burn to improve the users health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users fund
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, we won't be able to incentivize liquidators
     * 
     * for example , If the price of the collateral plummeted before anyone could be liquidated, 
     * 
     * follows CEI
     */


    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        // check if health factor of the user is broken

        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsNotBroken();
        }

        // we want to burn their DSC "Debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover = $100
        // $100 of DSC = ??? ETH

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // give the liquidator a 10% bonus
        // So we are given the liquidator $110 for $100 of WETH for 100 DSC
        // We should Implement a Feature to liquidate in the event the protocol is insolvent
        // And Sweep extra amounts into a treasury

        // 0.05 * 0.1 = 0.005. 0.05 + 0.005 = 0.055 
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);

    }

    function getHealthFactor() external view {}


    /////////////////////////////////////////////////
    //       Private & Internal view Functions     //
    /////////////////////////////////////////////////


    /**
     * 
     * @dev Low-level internal funnction, do not call unless the function calling it is 
     * checking for health factors being broken
     */

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;

        IERC20(i_dsc).safeTransferFrom(dscFrom, address(this), amountDscToBurn);

        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        IERC20(tokenCollateralAddress).safeTransfer(to, amountCollateral);
    }

    function _getAccountInformation(address user) private view returns(uint256 totalDSCMinted, uint256 collateralValueInUsd) {
        totalDSCMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user go below 1, they can get liqiudated
     */

    function _healthFactor(address user) private view returns(uint256) {
        // We need to get user total DSC minted
        // We need to get their total collateral Value

        (uint256 totalDSCMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDSCMinted;


        // return (collateralValueInUsd / totalDSCMinted);
    }

        // Check health factor (do they have enough collateral?)
        // revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {

        uint256 userHealthFactor = _healthFactor(user);

        if(userHealthFactor < MIN_HEALTH_FACTOR) {
                revert DSCEngine__BreaksHealthFactor(userHealthFactor);
            }


    }

    /////////////////////////////////////////////////
    //       Public & external view Functions     //
    /////////////////////////////////////////////////


    function getAccountCollateralValue(address user) public view returns(uint256 totalColateralValueInUsd) {
        //loop through each collateral token, get the amount they have deposited, and map it to 
        // the price feed value, to get the USD value of the collateral.

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalColateralValueInUsd += getUsdValue(token, amount);
        }

        return totalColateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
       AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
       (,int price,,,) = priceFeed.latestRoundData();

       if (price == 0) {
           revert DSCEngine__InvalidPrice();
       }
       // 1 ETH = 1000 USD
       // The return value is in 1e8
       return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // Price Of ETH (token)

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();

        // ($10e18 * 1e10) / ($2000e8 * 10e10)
        return (usdAmountInWei * PRECISION)  / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user) external view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
}
