pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IPosiStakingManager.sol";
import "./interfaces/IPositionReferral.sol";
import "./library/UserInfo.sol";

contract POSIAutoCompoundVault is ReentrancyGuard, Ownable {
    using SafeMath for uint256;
    using UserInfo for UserInfo.Data;
    IPositionReferral public positionReferral;
    IERC20 public posi = IERC20(0x5CA42204cDaa70d5c773946e69dE942b85CA6706);
    IPosiStakingManager public posiStakingManager = IPosiStakingManager(0x0C54B0b7d61De871dB47c3aD3F69FEB0F2C8db0B);
    address public router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    uint256 MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    uint256 public constant POSI_SINGLE_PID = 1;
    mapping(address => UserInfo.Data) public userInfo;
    uint256 public totalSupply;
    uint256 public rewardPerTokenStored;
    uint256 public lastPoolReward;
    uint256 public lastUpdatePoolReward;
    uint256 public referralCommissionRate;
    uint256 public percentFeeForCompounding;

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

    event Deposit(address account, uint256 amount);
    event Withdraw(address account, uint256 amount);
    event Harvest(address account, uint256 amount);
    event Compound(address account, uint256 amount);
    event RewardPaid(address account, uint256 reward);
    event ReferralCommissionPaid(
        address indexed user,
        address indexed referrer,
        uint256 commissionAmount
    );

    constructor() {
        approve();
    }

    function balanceOf(address user) public view returns(uint256) {
        return userInfo[msg.sender].amount;
    }

    function totalPoolRevenue() public view returns (uint256) {
        return totalPoolPendingRewards();
    }

    // rewards that ready to withdraw
    function totalPoolRewards() public view returns (uint256) {
        (uint256 depositedSinglePool,,,) = posiStakingManager.userInfo(POSI_SINGLE_PID, address(this));
        // total deposited sub 3% fees while withdrawn - total supply
        return depositedSinglePool.mul(97).div(100).sub(totalSupply).add(posi.balanceOf(address(this)));
    }

    function totalPoolPendingRewards() public view returns (uint256) {
        return posiStakingManager.pendingPosition(POSI_SINGLE_PID, address(this));
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
        posi.approve(address(posiStakingManager), MAX_INT);
        posi.approve(router, MAX_INT);
    }

    function deposit(uint256 amount) external nonReentrant updateReward(msg.sender) {
        posi.transferFrom(msg.sender, address(this), amount);
        // cannot use amount due to 1% RFI fees on transfer token
        uint256 stakeAmount = posi.balanceOf(address(this));
        posiStakingManager.deposit(POSI_SINGLE_PID, stakeAmount, address(this));
        userInfo[msg.sender].deposit(stakeAmount);
        totalSupply = totalSupply.add(amount);
        emit Deposit(msg.sender, stakeAmount);
    }

    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(userInfo[msg.sender].amount >= amount, "insufficient balance");
        // 3% fees applied
        posiStakingManager.withdraw(POSI_SINGLE_PID, amount);
        uint256 amountLeft = posi.balanceOf(address(this));
        posi.transfer(msg.sender, amountLeft);
        userInfo[msg.sender].withdraw(amountLeft);
        totalSupply = totalSupply.sub(amount);
        emit Withdraw(msg.sender, amount);
    }

    function harvest() external {
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
            posi.transfer(msg.sender, reward);
            payReferralCommission(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function compound() external {
        // function to compound for pool
        bool _canCompound = canCompound();
        if(_canCompound){
            uint256 balanceBefore = posi.balanceOf(address(this));
            posiStakingManager.deposit(POSI_SINGLE_PID, 0, address(this));
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

    function canCompound() public view returns (bool) {
        return posiStakingManager.canHarvest(POSI_SINGLE_PID, address(this));
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

}
