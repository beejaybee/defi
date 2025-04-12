// // SPDX-License-Identifier: MIT

// // Have our Invariants aka properties our system must hold true at all times

// // What are our invariants?

// // 1. The total supply of DSC should be less than the total value of the collateral

// // Our getter view function should never revert <-- evergreen invariant

// pragma solidity ^0.8.20;

// import { Test } from "forge-std/Test.sol";
// import { StdInvariant } from "forge-std/StdInvariant.sol";
// import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
// import { DscEngine } from "../../src/DscEngine.sol";
// import { DeployDsc } from "../../script/DeployDsc.s.sol";
// import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
// import { HelperConfig } from "../../script/HelperConfig.s.sol";
// import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantsTest is StdInvariant, Test {

//     DeployDsc deployer;
//     DecentralizedStableCoin dsc;
//     DscEngine dscEngine;
//     HelperConfig config;
//     address weth;
//     address wbtc;


//     function setUp() external {
//         deployer = new DeployDsc();
//         (dsc, dscEngine, config) = deployer.run();
//         (, , weth, wbtc ,) = config.activeNetworkConfig();
        
//         // Set the target contract for the invariant test
//         // targetContract(address(dscEngine));
//         // targetContract(address(dsc));
//         targetContract(address(config));

        
//     }

//     function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
//         // get the value of all the collateral in the protocol
//         // compare it to all the debt in the protocol (dsc total supply)

//         uint256 totalSupply = dsc.totalSupply();
//         uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
//         uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

//         uint256 wethValueInUsd = dscEngine.getUsdValue(weth, totalWethDeposited);
//         uint256 wbtcValueInUsd = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);
//         uint256 totalValueInUsd = wethValueInUsd + wbtcValueInUsd;

//         assert(totalValueInUsd >= totalSupply);
//     }
// }


