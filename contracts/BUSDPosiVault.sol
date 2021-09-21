pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IPosiStakingManager.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./library/UserInfo.sol";
import "./interfaces/IPositionReferral.sol";

/*
A vault that helps users stake in POSI farms and pools more simply.
Supporting auto compound in Single Staking Pool.
*/

contract BUSDPosiVault is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
    using SafeMath for uint256;
    using UserInfo for UserInfo.Data;

    // MAINNET
//    IERC20 public posi = IERC20(0x5CA42204cDaa70d5c773946e69dE942b85CA6706);
//    IERC20 public busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
//    IUniswapV2Router02 public router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
//    IUniswapV2Factory public factory = IUniswapV2Factory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
//    IPosiStakingManager public posiStakingManager = IPosiStakingManager(0x0C54B0b7d61De871dB47c3aD3F69FEB0F2C8db0B);
//    IPositionReferral public positionReferral;
//    uint256 public constant POSI_SINGLE_PID = 1;
//    uint256 public constant POSI_BUSD_PID = 0;

    // TESTNET
    IERC20 public posi = IERC20(0xb228359B5D83974F47655Ee41f17F3822A1fD0DD);
    IERC20 public busd = IERC20(0x787cF64b9F6E3d9E120270Cb84e8Ba1Fe8C1Ae09);
    IUniswapV2Router02 public router = IUniswapV2Router02(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);
    IUniswapV2Factory public factory = IUniswapV2Factory(0x6725F303b657a9451d8BA641348b6761A6CC7a17);
    IPosiStakingManager public posiStakingManager = IPosiStakingManager(0xD0A6C46316f789Ba3bdC320ebCC9AFdaE752fd73);
    IPositionReferral public positionReferral;
    uint256 public constant POSI_SINGLE_PID = 1;
    uint256 public constant POSI_BUSD_PID = 2;

    uint256 MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;

    mapping(address => UserInfo.Data) public userInfo;
    uint256 public totalSupply;
    uint256 public rewardPerTokenStored;
    uint256 public lastPoolReward;
    uint256 public lastUpdatePoolReward;
    uint256 public referralCommissionRate;
    uint256 public percentFeeForCompounding;

    event Deposit(address account, uint256 amount);
    event Withdraw(address account, uint256 amount);
    event Harvest(address account, uint256 amount);
    event Compound(address caller, uint256 reward);
    event RewardPaid(address account, uint256 reward);
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );

    modifier updateReward(address account) {
        // due to harvest lockup, lastPoolReward needs wait 8 hours to be updated
        // so we use condition to avoid gas wasting
        if(lastPoolReward != lastUpdatePoolReward) {
            rewardPerTokenStored = rewardPerToken();
            lastUpdatePoolReward = lastPoolReward;
            // need update rewardPerTokenStored to get different rewards
            if(account != address(0)){
                userInfo[account].updateReward(earned(account), rewardPerTokenStored);
            }
        }
        _;
    }

    function initialize(uint256 _referralCommissionRate) public initializer {
        approve();
    }

    function canCompound() public view returns (bool, uint256) {
        bool p1 = posiStakingManager.canHarvest(POSI_BUSD_PID, address(this));
        bool p2 = posiStakingManager.canHarvest(POSI_SINGLE_PID, address(this));
        return (p1 || p2, p2 ? POSI_SINGLE_PID : POSI_BUSD_PID);
    }

    function nearestCompoundingTime() public view returns (uint256) {
        (,,,uint256 pool1CompoundingTime) = posiStakingManager.userInfo(POSI_BUSD_PID, address(this));
        (,,,uint256 pool2CompoundingTime) = posiStakingManager.userInfo(POSI_SINGLE_PID, address(this));
        if(pool1CompoundingTime < pool2CompoundingTime){
            return pool1CompoundingTime;
        }
        return pool2CompoundingTime;
    }

    function balanceOf(address user) public view returns(uint256) {
        return getReserveInAmount1ByLP(userInfo[msg.sender].amount);
    }

    function totalPoolRevenue() public view returns (uint256) {
        return totalPoolPendingRewards().add(
            totalPoolRewards()
        );
    }

    // rewards that ready to withdraw
    function totalPoolRewards() public view returns (uint256) {
        (uint256 depositedSinglePool,,,) = posiStakingManager.userInfo(POSI_SINGLE_PID, address(this));
        // sub 3% fees while withdrawn
        return depositedSinglePool.mul(97).div(100).add(posi.balanceOf(address(this)));
    }

    function totalPoolPendingRewards() public view returns (uint256) {
        return posiStakingManager.pendingPosition(POSI_BUSD_PID, address(this))
                .add(posiStakingManager.pendingPosition(POSI_SINGLE_PID, address(this)));
    }

    // total user's rewards: pending + earned
    function pendingEarned(address account) public view returns(uint256) {
        return balanceOf(account).mul(
            pendingRewardPerToken()
            .sub(userInfo[account].rewardPerTokenPaid)
            .div(1e18)
            .add(userInfo[account].rewards)
        );
    }

    // total user's rewards ready to withdraw
    function earned(address account) public view returns(uint256) {
        return balanceOf(account).mul(
            rewardPerToken()
            .sub(userInfo[account].rewardPerTokenPaid)
            .div(1e18)
            .add(userInfo[account].rewards)
        );
    }

    function pendingRewardPerToken() public view returns(uint256) {
        return rewardPerToken().add(
            totalPoolPendingRewards().mul(1e18).div(totalSupply)
        );
    }

    function rewardPerToken() public view returns(uint256) {
        if(totalSupply == 0){
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored.add(
            (totalPoolRewards().sub(lastUpdatePoolReward)).mul(1e18).div(totalSupply)
        );
    }
    
    function getSwappingPair() public view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(
            factory.getPair(address(posi), address(busd))
        );
    }

    function updatePositionReferral(IPositionReferral _positionReferral) external onlyOwner {
        positionReferral = _positionReferral;
    }

    function updateReferralCommissionRate(uint256 _rate) external onlyOwner {
        referralCommissionRate = _rate;
    }

    function updatePercentFeeForCompounding(uint256 _rate) external onlyOwner {
        percentFeeForCompounding = _rate;
    }


    function approve() public {
        posi.approve(address(router), MAX_INT);
        busd.approve(address(router), MAX_INT);
        getSwappingPair().approve(address(posiStakingManager), MAX_INT);
        getSwappingPair().approve(address(router), MAX_INT);
    }

    function getReserveInAmount1ByLP(uint256 lp) public view returns (uint256 amount) {
        IUniswapV2Pair pair = getSwappingPair();
        uint256 balance0 = posi.balanceOf(address(pair));
        uint256 balance1 = busd.balanceOf(address(pair));
        uint256 totalSupply = pair.totalSupply();
        uint256 amount0 = lp.mul(balance0) / totalSupply;
        uint256 amount1 = lp.mul(balance1) / totalSupply;
        // convert amount0 -> amount1
        amount = amount1.add(amount0.mul(balance1).div(balance0));
    }
    
    function getLPTokenByAmount1(uint256 amount) public view returns (uint256 lpNeeded) {
         IUniswapV2Pair pair = getSwappingPair();
        (, uint256 res1, ) = pair.getReserves();
        uint256 totalSuply = pair.totalSupply();
        lpNeeded = amount.mul(totalSuply).div(res1).div(2);
    }

    function deposit(uint256 amount) external updateReward(msg.sender) nonReentrant {
        // function to deposit BUSD
        busd.transferFrom(msg.sender, address(this), amount);
        IUniswapV2Pair pair = getSwappingPair();
        (uint256 res0, uint256 res1, ) = pair.getReserves();
        uint256 amountToSwap = calculateSwapInAmount(res1, amount);
        (uint256[] memory amounts) = router.getAmountsOut(amountToSwap, getBusdPosiRoute());
        
        uint256 expectedPosiOut = amounts[1].mul(989).div(1000);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            getBusdPosiRoute(),
            address(this),
            block.timestamp
        );
        uint256 amountLeft =  amount.sub(amountToSwap);
        {
            // avoid stack too deep
            // add liquidity
            (,,uint256 liquidityAmount) = router.addLiquidity(
                address(posi),
                address(busd),
                expectedPosiOut,
                amountLeft,
                0,
                0,
                address(this),
                block.timestamp
            );
            //stake in farms
            posiStakingManager.deposit(POSI_BUSD_PID, liquidityAmount, address(this));
            //set state
            userInfo[msg.sender].deposit(amount);
            totalSupply = totalSupply.add(amount);
        }
        
    }

    function withdraw(uint256 amount) external updateReward(msg.sender) nonReentrant {
        require(balanceOf(msg.sender) >= amount, "invalid amount");
        // function to withdraw BUSD
        // first calculate how many posi needed in $amount
        (uint256[] memory amounts)= router.getAmountsIn(amount, getPosiBusdRoute());
        uint256 amountNeededInPosi = amounts[0].mul(10101).div(10000);
        //check in POSI pool
        uint256 balanceOfThis = posi.balanceOf(address(this));
        (uint256 stakedAmount,,,) = posiStakingManager.userInfo(POSI_SINGLE_PID, address(this));
        uint256 reserveAmount = balanceOfThis.add(stakedAmount);
        uint256 lpAmount = getLPTokenByAmount1(amount);
        if(reserveAmount >= amountNeededInPosi){
            // swap for more posi if contract balance is not enough
            if(balanceOfThis < amountNeededInPosi){
                posiStakingManager.withdraw(POSI_SINGLE_PID,  amountNeededInPosi.sub(balanceOfThis));
            }
            //swap for amount
            router.swapTokensForExactTokens(amount, 0, getPosiBusdRoute(), address(this), 0);
        }else{
            //withdraw from farm then remove liquidity
            //calculate LP needed
            posiStakingManager.withdraw(POSI_BUSD_PID, lpAmount);
            (uint256 amountA,uint256 amountB) = router.removeLiquidity(
                address(posi),
                address(busd),
                lpAmount,
                0,
                0,
                address(this),
                block.timestamp
            );
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountA, 0, getPosiBusdRoute(), address(this), block.timestamp);
            // amount = amounts[1].add(amountB);
        }
        busd.transfer(msg.sender, amount.mul(990).div(1000));
        // update state
        userInfo[msg.sender].withdraw(amount);
        totalSupply = totalSupply.sub(amount);
    }

    // withdraw LP only
    function emergencyWithdraw(uint256 lpAmount) external {
        require(userInfo[msg.sender].amount >= lpAmount, "!lp");
        posiStakingManager.withdraw(POSI_BUSD_PID, lpAmount);
        getSwappingPair().transfer(msg.sender, lpAmount);
        userInfo[msg.sender].withdraw(lpAmount);
    }

    function harvest(bool isReceiveBusd) external updateReward(msg.sender) {
        // function to harvest rewards
        uint256 reward = earned(msg.sender);
        if(reward > 0){
            userInfo[msg.sender].updateReward(0, 0);
            uint256 balanceOfThis = posi.balanceOf(address(this));
            (uint256 stakedAmount,,,) = posiStakingManager.userInfo(POSI_SINGLE_PID, address(this));
            uint256 reserveAmount = balanceOfThis.add(stakedAmount);
            if(balanceOfThis < reward){
                // cover 4 % fee
                posiStakingManager.withdraw(POSI_SINGLE_PID, reward.sub(balanceOfThis).mul(104).div(100));
            }
            if(isReceiveBusd){
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    reward,
                    0,
                    getPosiBusdRoute(),
                    msg.sender,
                    block.timestamp
                );
            }else{
                posi.transfer(msg.sender, reward);
            }
            payReferralCommission(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function compound() external nonReentrant {
        // function to compound for pool
        (bool _canCompound, uint256 pid) = canCompound();
        if(_canCompound){
            uint256 balanceBefore = posi.balanceOf(address(this));
            posiStakingManager.deposit(pid, 0, address(this));
            uint256 amountCollected = posi.balanceOf(address(this)).sub(balanceBefore);
            uint256 rewardForCaller = amountCollected.mul(percentFeeForCompounding).div(100);
            uint256 rewardForPool = amountCollected.sub(rewardForCaller);
            // stake to POSI pool
            posiStakingManager.deposit(POSI_SINGLE_PID, rewardForPool, address(this));
            posi.transfer(msg.sender, rewardForCaller);
            lastPoolReward = lastPoolReward.add(rewardForPool);
            emit Compound(msg.sender, rewardForPool);
        }
    }

    function payReferralCommission(address _user, uint256 _pending) internal {
        if(
            address(posiStakingManager) != address(0)
            && referralCommissionRate > 0
        ){
            address referrer = positionReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(
                10000
            );
            if (referrer != address(0) && commissionAmount > 0) {
                if(posi.balanceOf(address(this)) < commissionAmount){
                    posiStakingManager.withdraw(POSI_SINGLE_PID, commissionAmount);
                }
                posi.transfer(referrer, commissionAmount);
                positionReferral.recordReferralCommission(
                    referrer,
                    commissionAmount
                );
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    function getBusdPosiRoute() private view returns(address[] memory paths) {
        paths = new address[](2);
        paths[0] = address(busd);
        paths[1] = address(posi);
    }
    function getPosiBusdRoute() private view returns(address[] memory paths) {
        paths = new address[](2);
        paths[0] = address(posi);
        paths[1] = address(busd);
    }

    // follow:
    function calculateSwapInAmount(uint256 reserveIn, uint256 userIn)
    internal
    pure
    returns (uint256)
    {
        return
        sqrt(
            reserveIn.mul(userIn.mul(3988000) + reserveIn.mul(3988009))
        )
        .sub(reserveIn.mul(1997)) / 1994;
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
        // else z = 0
    }


}
