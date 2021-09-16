pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IPosiStakingManager.sol";
import "./library/UserInfo.sol";

contract POSIAutoCompoundVault is ReentrancyGuard {
    using UserInfo for UserInfo.Data;
    IERC20 public posi = IERC20(0x5CA42204cDaa70d5c773946e69dE942b85CA6706);
    IPosiStakingManager public posiStakingManager = IPosiStakingManager(0x0C54B0b7d61De871dB47c3aD3F69FEB0F2C8db0B);
    uint256 MAX_INT = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    uint256 public constant POSI_SINGLE_PID = 1;
    mapping(address => UserInfo.Data) public userInfo;
    uint256 public totalSupply;
    uint256 public rewardPerTokenStored;
    uint256 public lastPoolReward;
    uint256 public lastUpdatePoolReward;

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

    constructor() {
        approve();
    }

    function earned(
        address account
    ) public view returns (
        uint256
    ) {
        return 0;
    }

    function rewardPerToken() public view returns (uint256) {
        return 0;
    }

    function approve() public {
        posi.approve(address(posiStakingManager), MAX_INT);
    }

    function deposit(uint256 amount) external nonReentrant updateReward(msg.sender) {
        posi.transferFrom(msg.sender, address(this), amount);
        // cannot use amount due to 1% RFI fees on transfer token
        uint256 stakeAmount = posi.balanceOf(address(this));
        posiStakingManager.deposit(POSI_SINGLE_PID, stakeAmount, address(this));
        userInfo[msg.sender].deposit(stakeAmount);
        emit Deposit(msg.sender, stakeAmount);
    }

    function withdraw(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(userInfo[msg.sender].amount >= amount, "insufficient balance");
        // 3% fees applied
        posiStakingManager.withdraw(POSI_SINGLE_PID, amount);
        uint256 amountLeft = posi.balanceOf(address(this));
        posi.transfer(msg.sender, amountLeft);
        userInfo[msg.sender].withdraw(amountLeft);
        emit Withdraw(msg.sender, amount);
    }

    function harvest() external {
    }

    function compound() external {
    }

}
