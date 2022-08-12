// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "utils/BaseTest.sol";
import "script/VelodromeVolatileOpUsdc.s.sol";
import "interfaces/IBentoBoxV1.sol";
import "interfaces/ICauldronV3.sol";
import "interfaces/ISwapperV2.sol";
import "interfaces/ILevSwapperV2.sol";
import "interfaces/IVelodromePairFactory.sol";

contract VelodromeVolatileOpUsdcTest is BaseTest {
    address constant opWhale = 0x2501c477D0A35545a387Aa4A3EEe4292A9a8B3F0;
    address constant usdcWhale = 0xAD7b4C162707E0B2b5f6fdDbD3f8538A5fbA0d60;
    address constant rewardDistributor = 0x5d5Bea9f0Fc13d967511668a60a3369fD53F784F;

    event NotifyReward(address indexed from, address indexed reward, uint256 amount);
    event ClaimRewards(address indexed from, address indexed reward, uint256 amount);
    event LpMinted(uint256 total, uint256 strategyAmount, uint256 feeAmount);
    event LogStrategyProfit(address indexed token, uint256 amount);
    event LogStrategyDivest(address indexed token, uint256 amount);
    event LogStrategyQueued(address indexed token, address indexed strategy);

    ICauldronV3 cauldron;
    IBentoBoxV1 degenBox;
    ISwapperV2 swapper;
    ILevSwapperV2 levswapper;
    SolidlyGaugeVolatileLPStrategy strategy;
    IERC20 veloToken;
    IERC20 opToken;
    IERC20 usdcToken;
    IERC20 lp;
    ISolidlyGauge gauge;
    IVelodromePairFactory pairFactory;
    ISolidlyRouter router;

    uint256 fee;

    function setUp() public override {
        super.setUp();

        vm.createSelectFork(vm.envString("OPTIMISM_RPC_URL"), 18243290);
        VelodromeVolatileOpUsdcScript script = new VelodromeVolatileOpUsdcScript();
        script.setTesting(true);
        (cauldron, swapper, levswapper, strategy) = script.run();

        /*degenBox = IBentoBoxV1(constants.getAddress("optimism.degenBox"));
        gauge = ISolidlyGauge(constants.getAddress("optimism.velodrome.vOpUsdcGauge"));
        pairFactory = IVelodromePairFactory(constants.getAddress("optimism.velodrome.factory"));
        router = ISolidlyRouter(constants.getAddress("optimism.velodrome.router"));
        veloToken = IERC20(constants.getAddress("optimism.velodrome.velo"));
        lp = IERC20(constants.getAddress("optimism.velodrome.vOpUsdc"));
        opToken = IERC20(constants.getAddress("optimism.op"));
        usdcToken = IERC20(constants.getAddress("optimism.usdc"));
        fee = pairFactory.volatileFee();

        _mintLpToDegenBox();
        _activateStrategy();*/
    }

    function testOk() public {
        IOracle oracleBefore = IOracle(0x04146736FEF83A25e39834a972cf6A5C011ACEad);

        console2.log("oracle old", oracleBefore.peekSpot(""));
        console2.log("oracle new", cauldron.oracle().peekSpot(""));
    }

    /*function _mintLpToDegenBox() private {
        uint256 opAmount = 1000 * 1e18;
        uint256 usdcAmount = 5000 * 1e6;

        vm.startPrank(opWhale);
        opToken.transfer(alice, opAmount);
        vm.stopPrank();

        vm.startPrank(usdcWhale);
        usdcToken.transfer(alice, usdcAmount);
        vm.stopPrank();

        vm.startPrank(alice);
        opToken.approve(address(router), type(uint256).max);
        usdcToken.approve(address(router), type(uint256).max);
        router.addLiquidity(address(opToken), address(usdcToken), false, opAmount, usdcAmount, 0, 0, alice, type(uint256).max);

        uint256 lpAmount = lp.balanceOf(alice);
        assertGt(lpAmount, 0, "no lp minted");
        lp.approve(address(degenBox), type(uint256).max);
        degenBox.deposit(lp, alice, alice, lpAmount, 0);
        vm.stopPrank();
    }

    function _activateStrategy() private {
        vm.startPrank(degenBox.owner());
        degenBox.setStrategy(lp, strategy);
        advanceTime(1210000);
        degenBox.setStrategy(lp, strategy);
        degenBox.setStrategyTargetPercentage(lp, 70);
        vm.stopPrank();

        // Initial Rebalance, calling skim to deposit to the gauge
        vm.startPrank(deployer);
        strategy.safeHarvest(type(uint256).max, true, 0, false);
        assertEq(lp.balanceOf(address(strategy)), 0);
        assertEq(veloToken.balanceOf(address(strategy)), 0);
        vm.stopPrank();
    }

    function _distributeRewards() private {
        advanceTime(1210000);
        uint256 amount = 50000 * 1e18;

        vm.prank(rewardDistributor);
        veloToken.transfer(address(gauge), amount);

        vm.startPrank(address(gauge));
        veloToken.approve(address(gauge), 0);
        veloToken.approve(address(gauge), amount);

        vm.expectEmit(true, true, false, true);
        emit NotifyReward(address(gauge), address(veloToken), amount);
        gauge.notifyRewardAmount(address(veloToken), amount);
        advanceTime(5);
        vm.stopPrank();
    }

    function _transferRewardsToStrategy(uint256 amount) private {
        vm.prank(rewardDistributor);
        veloToken.transfer(address(strategy), amount);
    }

    function testFarmRewards() public {
        uint256 previousAmount = veloToken.balanceOf(address(strategy));
        _distributeRewards();

        vm.startPrank(deployer);
        strategy.safeHarvest(type(uint256).max, false, 0, false);
        vm.stopPrank();

        assertGt(veloToken.balanceOf(address(strategy)), previousAmount, "no velo harvested");
    }

    function testFeeParameters() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        strategy.setFeeParameters(alice, 15);

        vm.prank(deployer);
        strategy.setFeeParameters(alice, 15);
        assertEq(strategy.feeCollector(), alice);
        assertEq(strategy.feePercent(), 15);
    }

    function testMintLpFromRewardsTakeFees() public {
        vm.prank(deployer);
        strategy.setFeeParameters(deployer, 10);

        _distributeRewards();

        vm.startPrank(deployer);
        strategy.safeHarvest(0, false, 0, false);

        uint256 balanceFeeCollector = lp.balanceOf(deployer);
        uint256 balanceStrategy = lp.balanceOf(address(strategy));
        vm.stopPrank();

        _transferRewardsToStrategy(4_000_000 * 1e18);

        vm.startPrank(deployer);
        // Check that LpMinted event is emitted
        vm.expectEmit(false, false, false, false);
        emit LpMinted(0, 0, 0);
        strategy.swapToLP(0, fee);

        // Strategy and FeeCollector should now have more LP
        assertGt(lp.balanceOf(deployer), balanceFeeCollector);
        assertGt(lp.balanceOf(address(strategy)), balanceStrategy);
        vm.stopPrank();
    }

    function testStrategyProfit() public {
        uint256 degenBoxBalance = degenBox.totals(lp).elastic;

        vm.prank(deployer);
        strategy.safeHarvest(0, false, 0, false);

        _transferRewardsToStrategy(4_000_000 * 1e18);
        vm.startPrank(deployer);
        strategy.swapToLP(0, fee);

        vm.expectEmit(true, false, false, false);
        emit LogStrategyProfit(address(lp), 0);
        strategy.safeHarvest(0, false, 0, false);
        
        assertGt(degenBox.totals(lp).elastic, degenBoxBalance);
    }

    function testStrategyDivest() public {
        uint256 degenBoxBalance = lp.balanceOf(address(degenBox));

        vm.startPrank(deployer);
        degenBox.setStrategyTargetPercentage(lp, 50);

        vm.expectEmit(true, false, false, false);
        emit LogStrategyDivest(address(lp), 0);
        strategy.safeHarvest(0, true, 0, false);

        assertGt(lp.balanceOf(address(degenBox)), degenBoxBalance);
    }

    function testStrategyExit() public {
        uint256 degenBoxBalance = lp.balanceOf(address(degenBox));

        _distributeRewards();

        vm.prank(deployer);
        strategy.safeHarvest(0, true, 0, false);
        _transferRewardsToStrategy(4_000_000 * 1e18);

        vm.startPrank(deployer);
        strategy.swapToLP(0, fee);

        vm.expectEmit(true, true, false, false);
        emit LogStrategyQueued(address(lp), address(strategy));
        degenBox.setStrategy(lp, strategy);
        advanceTime(1210000);

        vm.expectEmit(true, false, false, false);
        emit LogStrategyDivest(address(lp), 0);
        degenBox.setStrategy(lp, strategy);

        assertGt(lp.balanceOf(address(degenBox)), degenBoxBalance);
        assertEq(lp.balanceOf(address(strategy)), 0);
    }*/
}
