// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from
    "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DSCEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if
        // redeemFrom != redeemedTo, then it was liquidated

    DSCEngine public engine;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31_337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__tokenAddressAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = engine.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = engine.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    // function testRevertsWithUnapprovedCollateral() public {
    //     ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
    //     vm.startPrank(user);
    //     vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, address(randToken)));
    //     engine.depositCollateral(address(randToken), amountCollateral);
    //     vm.stopPrank();
    // }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInfo(user);
        uint256 expectedDepositedAmount = engine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDSC Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (amountCollateral * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDSC Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.mintDSC(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint =
            (amountCollateral * (uint256(price) * engine.getAdditionalFeedPrecision())) / engine.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        engine.mintDSC(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        engine.mintDSC(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDSC Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        engine.burnDSC(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(engine), amountToMint);
        engine.burnDSC(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
        mockDsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), amountCollateral);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBeforeRedeem = engine.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceBeforeRedeem, amountCollateral);
        engine.redeemCollateral(weth, amountCollateral);
        uint256 userBalanceAfterRedeem = engine.getCollateralBalanceOfUser(user, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    // function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
    //     vm.startPrank(user);
    //     vm.expectEmit(true, true, true, true, address(this));
    //     emit CollateralRedeemed(user, user, weth, amountCollateral);

    //     engine.redeemCollateral(weth, amountCollateral);
    //     vm.stopPrank();
    // }
    ///////////////////////////////////
    // redeemCollateralForDSC Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(engine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.redeemCollateralForDSC(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.redeemCollateralForDSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = engine.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = engine.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    // function testMustImproveHealthFactorOnLiquidation() public {
    //     // Arrange - Setup
    //     MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
    //     tokenAddresses = [weth];
    //     feedAddresses = [ethUsdPriceFeed];
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
    //     mockDsce.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();

    //     // Arrange - Liquidator
    //     collateralToCover = 1 ether;
    //     ERC20Mock(weth).mint(liquidator, collateralToCover);

    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
    //     uint256 debtToCover = 10 ether;
    //     mockDsce.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
    //     mockDsc.approve(address(mockDsce), debtToCover);
    //     // Act
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //     // Act/Assert
    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImporved.selector);
    //     mockDsce.liquidate(weth, user, debtToCover);
    //     vm.stopPrank();
    // }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        engine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateralAndMintDSC(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = engine.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(engine), collateralToCover);
        engine.depositCollateralAndMintDSC(weth, collateralToCover, amountToMint);
        dsc.approve(address(engine), amountToMint);
        engine.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = engine.getTokenAmountFromUsd(weth, amountToMint)
            + (
                engine.getTokenAmountFromUsd(weth, amountToMint) * engine.getLiquidationBonus()
                    / engine.getLiquidationPrecision()
            );
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = engine.getTokenAmountFromUsd(weth, amountToMint)
            + (
                engine.getTokenAmountFromUsd(weth, amountToMint) * engine.getLiquidationBonus()
                    / engine.getLiquidationPrecision()
            );

        uint256 usdAmountLiquidated = engine.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = engine.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = engine.getAccountInfo(user);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted,) = engine.getAccountInfo(liquidator);
        assertEq(liquidatorDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = engine.getAccountInfo(user);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = engine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = engine.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = engine.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = engine.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = engine.getAccountInfo(user);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = engine.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(engine), amountCollateral);
        engine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = engine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = engine.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = engine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = engine.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDsc {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(engine));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(engine));

    //     uint256 wethValue = engine.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = engine.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
