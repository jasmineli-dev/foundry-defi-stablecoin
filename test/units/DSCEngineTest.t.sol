//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";

contract DSCEngineTest is Test {
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    );
    // redeemFrom != redeemedTo, then it was liquidated

    DSCEngine dscEngine;
    DecentralizedStableCoin dsc;
    DeployDSCEngine deployer;
    HelperConfig helpconfig;
    address weth;
    address wbtc;
    address ethPriceFeed;
    address btcPriceFeed;
    address public user = makeAddr("user");
    uint256 amountCollateral = 10 ether; //10 * 10^18;
    uint256 amountToMint = 100 ether; //100 * 10^18;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSCEngine();
        (dsc, dscEngine, helpconfig) = deployer.run();
        (ethPriceFeed, btcPriceFeed, weth, wbtc, ) = helpconfig
            .activeNetworkConfig();
        ERC20Mock(weth).mint(user, 100e18);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethPriceFeed);
        feedAddresses.push(btcPriceFeed);

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch
                .selector
        );
        new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    }

    ///////////////////////////
    //// Test Get USD Value
    ///////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18; //15 ETH expressed in wei==15 * 10^18
        uint256 ethUsdValue = dscEngine.getUsdValue(weth, ethAmount);
        // ethUsdPriceFeed is 2000_00000000
        // int256 constant initialAnswer_ETH = 2000e8;
        assertEq(ethUsdValue, 30e21);
    }

    ///////////////////////////
    //// test collateral
    ///////////////////////////
    function testRevertIfCollateralIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral); //Prevent unintended reverts (like insufficient allowance)

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    function testRevertsIfTransferFromFails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        tokenAddresses = [address(mockCollateralToken)];
        feedAddresses = [ethPriceFeed];
        // DSCEngine receives the third parameter as dscAddress, not the tokenAddress used as collateral.
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(dsc)
        );
        mockCollateralToken.mint(user, amountCollateral);
        vm.startPrank(user);
        ERC20Mock(address(mockCollateralToken)).approve(
            address(mockDsce),
            amountCollateral
        );
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(
            address(mockCollateralToken),
            amountCollateral
        );
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__TokenNotAllowed.selector,
                address(randToken)
            )
        );
        dscEngine.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting()
        public
        depositedCollateral
    {
        // depositing collateral and minting stablecoins are separate operations.
        // A user can lock up collateral without immediately borrowing against it
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInformation(user);
        uint256 expectedDepositedAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        assertEq(totalDscMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethPriceFeed)
            .latestRoundData(); //price = 200000000000 [2e11]
        uint256 ToMint = ((amountCollateral *
            (uint256(price) * dscEngine.getAdditionalFeedPrecision())) /
            dscEngine.getPrecision()); // ToMint = 20,000 DSC tokens
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);

        //MIN_HEALTH_FACTOR = 1e18;
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            ToMint,
            dscEngine.getUsdValue(weth, amountCollateral)
        ); // LIQUIDATION_THRESHOLD = 50
        //Health Factor=  (Total Debt Collateral Value x Liquidation Threshold / Total debts
        //Health Factor= 5e17 < 1e18

        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor //500000000000000000 [5e17] < 1e18, so it would revert;
            )
        );
        dscEngine.depositCollateralAndMintDsc(weth, amountCollateral, ToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDsc Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        feedAddresses = [ethPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        // dscEngine.depositCollateralAndMintDsc(
        //     weth,
        //     amountCollateral,
        //     amountToMint
        // );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor()
        public
        depositedCollateral
    {
        (, int256 price, , , ) = MockV3Aggregator(ethPriceFeed)
            .latestRoundData();
        uint256 ToMint = (amountCollateral *
            (uint256(price) * dscEngine.getAdditionalFeedPrecision())) /
            dscEngine.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            ToMint,
            dscEngine.getUsdValue(weth, amountCollateral)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dscEngine.mintDsc(ToMint); // mark
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dscEngine.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    function testCannotMintWithoutDepositingCollateral() public {
        vm.startPrank(user);

        // Do NOT deposit collateral; do NOT approve anything.
        // Try to mint — should revert because health factor will be broken.
        // With 0 collateral, the health factor will be 0
        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
            amountToMint,
            0
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dscEngine.mintDsc(amountToMint);

        vm.stopPrank();
    }

    ///////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dscEngine.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.burnDsc(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    // use the test contract address for setup/admin actions, use test addresses for simulating real user behavior.
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        feedAddresses = [ethPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );
        mockDsc.mint(user, amountCollateral);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        //FROM: Test contract (current owner)
        //TO: mockDsce (the DSCEngine contract)
        // This is a common pattern in DeFi: the main protocol contract (Engine) owns the token contract
        // so it can mint/burn as needed during deposits/withdrawals.

        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDsc)).approve(
            address(mockDsce),
            amountCollateral
        );
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), amountCollateral); // called transferFrom
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBeforeRedeem = dscEngine.getCollateralBalanceOfUser(
            user,
            weth
        );
        assertEq(userBalanceBeforeRedeem, amountCollateral);
        dscEngine.redeemCollateral(weth, amountCollateral);
        uint256 userBalanceAfterRedeem = dscEngine.getCollateralBalanceOfUser(
            user,
            weth
        );
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs()
        public
        depositedCollateral
    {
        vm.expectEmit(true, true, true, true, address(dscEngine));
        //This is the most explicit and safest approach, check all parameters;
        //vm.expectEmit() only accepts up to five parameters.
        //You can't have more than 3 indexed parameters - Solidity won't compile it

        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        dscEngine.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero()
        public
        depositedCollateralAndMintedDsc
    {
        vm.startPrank(user);
        dsc.approve(address(dscEngine), amountToMint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dscEngine.redeemCollateralForDsc(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral); //User approves the engine to spend their ETH tokens
        // dsc.approve(address(dscEngine), amountToMint);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        dsc.approve(address(dscEngine), amountToMint); //User approves the dscEngine to spend this user's DSC tokens
        dscEngine.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        uint256 expectedHealthFactor = 100 ether; //100 * 10^18;
        //  dscEngine.calculateHealthFactor(
        //     amountToMint,
        //     dscEngine.getUsdValue(weth, amountCollateral)
        // );
        uint256 healthFactor = dscEngine.getHealthFactor(user);
        // uint256 amountCollateral = 10 ether;      // 10 * 10^18
        // uint256 amountToMint = 100 ether;         // 100 * 10^18
        // uint256 initialAnswer_ETH = 2000e8;       // $2000 per ETH
        // uint256 LIQUIDATION_THRESHOLD = 50;       // 50%
        // uint256 PRECISION = 1e18;

        // Collateral in ETH: 10 * 10^18
        // ETH Price: 2000 * 10^8 (Chainlink format: 8 decimals)

        // Total USD Value = (10 * 10^18) * (2000 * 10^8) / 10^8 = 10 * 2000 * 10^18 = 20,000 * 10^18 = $20,000
        // Collateral Adjusted = 20,000 * 10^18 * 50 / 100 = 10,000 * 10^18 = $10,000 (the amount you can safely borrow against)
        // Health Factor = (10,000 * 10^18) / (100 * 10^18) = 10,000 / 100 = 100 * 10^18 (when expressed with PRECISION) = 100 ether

        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne()
        public
        depositedCollateralAndMintedDsc
    {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dscEngine.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethPriceFeed);
        //This mock crashes the price to $0 when burn() is called (see the mock contract)
        tokenAddresses = [weth];
        feedAddresses = [ethPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(
            tokenAddresses,
            feedAddresses,
            address(mockDsc)
        );
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
        mockDsce.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            amountToMint
        );
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        // Make it liquidatable
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        // Act/Assert
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            collateralToCover,
            amountToMint
        );
        dsc.approve(address(dscEngine), amountToMint);

        // liquidator liquidate user
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            amountCollateral,
            amountToMint
        );
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(
            weth,
            collateralToCover, //20eth
            amountToMint // 100 x 10^18 ← Liquidator mints their own debt!
        );
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(
            weth,
            amountToMint
        ) +
            ((dscEngine.getTokenAmountFromUsd(weth, amountToMint) *
                dscEngine.getLiquidationBonus()) /
                dscEngine.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        //100 DSC ÷ $18/ETH = 5.555... ETH, plus a 10% bonus = 0.555... ETH, giving us 6.111... ETH

        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dscEngine.getTokenAmountFromUsd(
            weth,
            amountToMint
        ) +
            ((dscEngine.getTokenAmountFromUsd(weth, amountToMint) *
                dscEngine.getLiquidationBonus()) /
                dscEngine.getLiquidationPrecision());

        uint256 usdAmountLiquidated = dscEngine.getUsdValue(
            weth,
            amountLiquidated
        );
        uint256 expectedUserCollateralValueInUsd = dscEngine.getUsdValue(
            weth,
            amountCollateral
        ) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dscEngine.getAccountInformation(
            user
        );
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
        // Initial collateral: 10 ETH × $18 = 180e18 wei USD
        // Liquidated amount: 6.111...110 ETH × $18 = 109_999_999_999_999_999_980 wei USD
        // Remaining: 180e18 - 109_999_999_999_999_999_980 = 70_000_000_000_000_000_020 wei USD ✅
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDscMinted, ) = dscEngine.getAccountInformation(
            liquidator
        );
        assertEq(liquidatorDscMinted, amountToMint);
    }

    // the liquidator's debt of 100 DSC remains

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted, ) = dscEngine.getAccountInformation(user);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dscEngine.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethPriceFeed); //ETH original price
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

    function testGetAccountCollateralValueFromInformation()
        public
        depositedCollateral
    {
        (, uint256 collateralValue) = dscEngine.getAccountInformation(user);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(
            weth,
            amountCollateral
        );
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = dscEngine.getCollateralBalanceOfUser(
            user,
            weth
        );
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = dscEngine.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dscEngine.getUsdValue(
            weth,
            amountCollateral
        );
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDsc() public {
        address dscAddress = dscEngine.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dscEngine
            .getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    function testInvariantBreaks() public depositedCollateralAndMintedDsc {
        //MockV3Aggregator(ethPriceFeed).updateAnswer(0);

        uint256 totalSupply = dsc.totalSupply();
        uint256 wethDeposited = ERC20Mock(weth).balanceOf(address(dscEngine));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dscEngine));

        uint256 wethValue = dscEngine.getUsdValue(weth, wethDeposited);
        uint256 wbtcValue = dscEngine.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);
        console.log("totalSupply: %s", totalSupply);

        assert(wethValue + wbtcValue >= totalSupply); //CHECK INVARIANT: Collateral >= Debt
    }
}
