// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../MockLpToken.sol";
import "../IMockLpTokenFactory.sol";
import "../IFateRewardController.sol";

import "./IRewardScheduleV3.sol";
import "./IFateRewardControllerV3.sol";
import "./MembershipWithReward.sol";

// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once FATE is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract FateRewardControllerV3 is IFateRewardControllerV3, MembershipWithReward {
    using SafeERC20 for IERC20;
    address public fateFeeTo;

    // feeReserves tracks the amount of fees per token
    mapping (address => uint256) public feeReserves;

    // Info of each user.
    struct UserInfoV3 {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lockedRewardDebt; // Reward debt. See explanation below.
        bool isUpdated; // true if the user has been migrated from the v1 controller to v2
        //
        // We do some fancy math here. Basically, any point in time, the amount of FATEs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accumulatedFatePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accumulatedFatePerShare` (and `lastRewardTimestamp`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    IERC20 public override fate;

    IRewardScheduleV3 public override rewardSchedule;

    address public override vault;

    IFateRewardController[] public oldControllers;

    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public override migrator;

    // Info of each pool.
    PoolInfoV3[] public override poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfoV3)) internal _userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public override totalAllocPoint = 0;

    // The timestamp when FATE mining starts.
    uint256 public override startTimestamp;

    IMockLpTokenFactory public mockLpTokenFactory;

    bool public allowEmergencyWithdrawal;

    // address of FeeTokenConverterToFate contract
    event FateFeeToSet(address _fateFeeTo);

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);

    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event ClaimRewards(address indexed user, uint256 indexed pid, uint256 amount);

    event EmergencyWithdrawalAllowedSet(bool allowEmergencyWithdrawal);

    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event RewardScheduleSet(address indexed rewardSchedule);

    event MigratorSet(address indexed migrator);

    event VaultSet(address indexed rewardSchedule);

    event PoolAdded(uint indexed pid, address indexed lpToken, uint allocPoint);

    event PoolAllocPointSet(uint indexed pid, uint allocPoint);

    constructor(
        IERC20 _fate,
        IRewardScheduleV3 _rewardSchedule,
        address _vault,
        IFateRewardController[] memory _oldControllers,
        IMockLpTokenFactory _mockLpTokenFactory,
        uint256 _startTimestamp,
        address _fateFeeTo
    ) public {
        require(
            _startTimestamp > 0,
            "_startTimestamp must not be 0"
        );

        fate = _fate;
        rewardSchedule = _rewardSchedule;
        vault = _vault;
        oldControllers = _oldControllers;
        mockLpTokenFactory = _mockLpTokenFactory;
        startTimestamp = _startTimestamp;
        fateFeeTo = _fateFeeTo;

        if (_oldControllers.length > 0) {
            // reset old controller's pooInfo
            for (uint i = 0; i < _oldControllers[0].poolLength(); i++) {
                (IERC20 lpToken, uint256 allocPoint, ,) = _oldControllers[0].poolInfo(i);
                poolInfo.push(
                    PoolInfoV3({
                        lpToken: lpToken,
                        allocPoint: allocPoint,
                        lastRewardTimestamp: _startTimestamp,
                        accumulatedFatePerShare: 0,
                        accumulatedLockedFatePerShare: 0
                    })
                );
                totalAllocPoint = totalAllocPoint.add(allocPoint);
            }
        }
    }

    function setStartTimestamp(uint256 _startTimestamp) external onlyOwner {
        require(startTimestamp == uint(-1), "setStartTimestamp: already initialized");
        startTimestamp = _startTimestamp;
        for (uint i = 0; i < poolInfo.length; i++) {
            poolInfo[i].lastRewardTimestamp = _startTimestamp;
        }
    }

    function setFateFeeTo(address _fateFeeTo) external onlyOwner {
        require(_fateFeeTo != address(0), 'setFateFeeTo: invalid feeTo');
        fateFeeTo = _fateFeeTo;
        emit FateFeeToSet(fateFeeTo);
    }

    function poolLength() public override view returns (uint256) {
        return poolInfo.length;
    }

    function addMany(
        IERC20[] calldata _lpTokens
    ) external onlyOwner {
        uint allocPoint = 0;
        for (uint i = 0; i < _lpTokens.length; i++) {
            bool shouldUpdate = i == _lpTokens.length - 1;
            _add(allocPoint, _lpTokens[i], shouldUpdate);
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        _add(_allocPoint, _lpToken, _withUpdate);
    }

    function getPoolInfoId(address _lpToken) external view returns (uint256) {
        for(uint i = 0; i < poolInfo.length; i++) {
            if(address(poolInfo[i].lpToken) == _lpToken) {
                return i + 1;
            }
        }
        return 0;
    }

    function _add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) internal {
        for (uint i = 0; i < poolInfo.length; i++) {
            require(
                poolInfo[i].lpToken != _lpToken,
                "add: LP token already added"
            );
        }

        if (_withUpdate) {
            massUpdatePools();
        }
        require(
            _lpToken.balanceOf(address(this)) >= 0,
            "add: invalid LP token"
        );

        uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfoV3({
                lpToken : _lpToken,
                allocPoint : _allocPoint,
                lastRewardTimestamp : lastRewardTimestamp,
                accumulatedFatePerShare : 0,
                accumulatedLockedFatePerShare : 0
            })
        );
        emit PoolAdded(poolInfo.length - 1, address(_lpToken), _allocPoint);
    }

    // Update the given pool's FATE allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        _set(_pid, _allocPoint, _withUpdate);
    }

    // Update the given pool's FATE allocation point. Can only be called by the owner.
    function setMany(
        uint256[] calldata _pids,
        uint256[] calldata _allocPoints
    ) external onlyOwner {
        require(
            _pids.length == _allocPoints.length,
            "setMany: invalid length"
        );
        for (uint i = 0; i < _pids.length; i++) {
            _set(_pids[i], _allocPoints[i], i == _pids.length - 1);
        }
    }

    function getFeeReserves(address _token) external view returns (uint256)
    {
        return feeReserves[_token];
    }

    // Update the given pool's FATE allocation point. Can only be called by the owner.
    function setManyWith2dArray(
        uint256[][] calldata _pidsAndAllocPoints
    ) external onlyOwner {
        uint _poolLength = poolInfo.length;
        for (uint i = 0; i < _pidsAndAllocPoints.length; i++) {
            uint[] memory _pidAndAllocPoint = _pidsAndAllocPoints[i];
            require(
                _pidAndAllocPoint.length == 2,
                "setManyWith2dArray: invalid length, expected 2"
            );
            require(
                _pidAndAllocPoint[0] < _poolLength,
                "setManyWith2dArray: invalid pid"
            );
            _set(
                _pidAndAllocPoint[0],
                _pidAndAllocPoint[1],
                /* withUpdate */ i == _pidsAndAllocPoints.length - 1
            );
        }
    }

    function _set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) internal {
        if (_withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        emit PoolAllocPointSet(_pid, _allocPoint);
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public override onlyOwner {
        migrator = _migrator;
        emit MigratorSet(address(_migrator));
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrateLpToken(uint256 _pid) public override {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfoV3 storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    function migrate(
        IERC20 token
    ) external override returns (IERC20) {
        IFateRewardController oldController = IFateRewardController(address(0));
        for (uint i = 0; i < oldControllers.length; i++) {
            if (address(oldControllers[i]) == msg.sender) {
                oldController = oldControllers[i];
            }
        }
        require(
            address(oldController) != address(0),
            "migrate: invalid sender"
        );

        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardTimestamp;
        uint256 accumulatedFatePerShare;
        uint oldPoolLength = oldController.poolLength();
        for (uint i = 0; i < oldPoolLength; i++) {
            (lpToken, allocPoint, lastRewardTimestamp, accumulatedFatePerShare) = oldController.poolInfo(poolInfo.length);
            if (address(lpToken) == address(token)) {
                break;
            }
        }

        // transfer all of the tokens from the previous controller to here
        token.transferFrom(msg.sender, address(this), token.balanceOf(msg.sender));

        poolInfo.push(
            PoolInfoV3({
                lpToken : lpToken,
                allocPoint : allocPoint,
                lastRewardTimestamp : lastRewardTimestamp,
                accumulatedFatePerShare : accumulatedFatePerShare,
                accumulatedLockedFatePerShare : 0
            })
        );
        emit PoolAdded(poolInfo.length - 1, address(token), allocPoint);

        uint _totalAllocPoint = 0;
        for (uint i = 0; i < poolInfo.length; i++) {
            _totalAllocPoint = _totalAllocPoint.add(poolInfo[i].allocPoint);
        }
        totalAllocPoint = _totalAllocPoint;

        return IERC20(mockLpTokenFactory.create(address(lpToken), address(this)));
    }

    function userInfo(
        uint _pid,
        address _user
    ) public override view returns (uint amount, uint rewardDebt) {
        UserInfoV3 memory user = _userInfo[_pid][_user];
        return (user.amount, user.rewardDebt);
    }

    function _getUserInfo(
        uint _pid,
        address _user
    ) public view returns (IFateRewardControllerV3.UserInfo memory) {
        UserInfoV3 memory user = _userInfo[_pid][_user];
        return IFateRewardControllerV3.UserInfo(user.amount, user.rewardDebt, user.lockedRewardDebt);
    }

    // View function to see pending FATE tokens on frontend.
    function pendingUnlockedFate(
        uint256 _pid,
        address _user
    )
    public
    override
    view
    returns (uint256)
    {
        PoolInfoV3 storage pool = poolInfo[_pid];
        IFateRewardControllerV3.UserInfo memory user = _getUserInfo(_pid, _user);
        uint256 accumulatedFatePerShare = pool.accumulatedFatePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0 && totalAllocPoint != 0) {
            (, uint256 unlockedFatePerSecond) = rewardSchedule.getFateForDuration(
                startTimestamp,
                pool.lastRewardTimestamp,
                block.timestamp
            ); // only unlocked Fates
            uint256 unlockedFateReward = unlockedFatePerSecond
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accumulatedFatePerShare = accumulatedFatePerShare
                .add(unlockedFateReward.mul(1e12).div(lpSupply));
        }
        return user.amount
            .mul(accumulatedFatePerShare)
            .div(1e12)
            .sub(user.rewardDebt);
    }

    function pendingLockedFate(
        uint256 _pid,
        address _user
    )
    public
    override
    view
    returns (uint256)
    {
        PoolInfoV3 storage pool = poolInfo[_pid];
        IFateRewardControllerV3.UserInfo memory user = _getUserInfo(_pid, _user);
        uint256 accumulatedLockedFatePerShare = pool.accumulatedLockedFatePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0 && totalAllocPoint != 0) {
            (uint256 lockedFatePerSecond,) = rewardSchedule.getFateForDuration(
                startTimestamp,
                pool.lastRewardTimestamp,
                block.timestamp
            ); // only locked Fates
            uint256 lockedFateReward = lockedFatePerSecond
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accumulatedLockedFatePerShare = accumulatedLockedFatePerShare.add(lockedFateReward.mul(1e12).div(lpSupply));
        }

        uint lockedReward = user.amount.mul(accumulatedLockedFatePerShare).div(1e12).sub(user.lockedRewardDebt);
        return getEffectiveRewardAfterRewardFee(_pid, _user, lockedReward);
    }

    function allPendingUnlockedFate(
        address _user
    )
    external
    override
    view
    returns (uint256)
    {
        uint _pendingFateRewards = 0;
        for (uint i = 0; i < poolInfo.length; i++) {
            _pendingFateRewards = _pendingFateRewards.add(pendingUnlockedFate(i, _user));
        }
        return _pendingFateRewards;
    }

    function allPendingLockedFate(
        address _user
    )
    external
    override
    view
    returns (uint256)
    {
        uint _pendingFateRewards = 0;
        for (uint i = 0; i < poolInfo.length; i++) {
            _pendingFateRewards = _pendingFateRewards.add(pendingLockedFate(i, _user));
        }
        return _pendingFateRewards;
    }

    function allLockedFate(
        address _user
    )
    external
    override
    view
    returns (uint256)
    {
        uint _pendingFateRewards = 0;
        for (uint i = 0; i < poolInfo.length; i++) {
            _pendingFateRewards = _pendingFateRewards.add(pendingLockedFate(i, _user)).add(userLockedRewards[i][_user]);
        }
        return _pendingFateRewards;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function getNewRewardPerSecond(uint pid1) public view returns (uint) {
        (, uint256 fatePerSecond) = rewardSchedule.getFateForDuration(
            startTimestamp,
            block.timestamp - 1,
            block.timestamp
        );
        if (pid1 == 0) {
            return fatePerSecond;
        } else if (totalAllocPoint != 0) {
            return fatePerSecond.mul(poolInfo[pid1 - 1].allocPoint).div(totalAllocPoint);
        } else {
            return 0;
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfoV3 storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTimestamp = block.timestamp;
            return;
        }

        (uint256 lockedFatePerSecond, uint256 unlockedFatePerSecond) = rewardSchedule.getFateForDuration(
            startTimestamp,
            pool.lastRewardTimestamp,
            block.timestamp
        );

        uint256 unlockedFateReward = totalAllocPoint != 0
            ? unlockedFatePerSecond.mul(pool.allocPoint).div(totalAllocPoint)
            : 0;
        uint256 lockedFateReward = totalAllocPoint != 0
            ? lockedFatePerSecond.mul(pool.allocPoint).div(totalAllocPoint)
            : 0;

        if (unlockedFateReward > 0) {
            fate.transferFrom(vault, address(this), unlockedFateReward);
            if (lpSupply != 0) {
                pool.accumulatedFatePerShare = pool.accumulatedFatePerShare
                    .add(unlockedFateReward.mul(1e12).div(lpSupply));
            }
        }
        if (lockedFateReward > 0) {
            if (lpSupply != 0) {
                pool.accumulatedLockedFatePerShare = pool.accumulatedLockedFatePerShare
                    .add(lockedFateReward.mul(1e12).div(lpSupply));
            }
        }
        pool.lastRewardTimestamp = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for FATE allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfoV3 storage pool = poolInfo[_pid];
        IFateRewardControllerV3.UserInfo memory user = _getUserInfo(_pid, msg.sender);
        updatePool(_pid);
        if (user.amount > 0) {
            _claimRewards(_pid, msg.sender, user, pool);
        }
        pool.lpToken.transferFrom(
            address(msg.sender),
            address(this),
            _amount
        );

        uint userBalance = user.amount.add(_amount);
        _userInfo[_pid][msg.sender] = UserInfoV3({
            amount : userBalance,
            rewardDebt : userBalance.mul(pool.accumulatedFatePerShare).div(1e12),
            lockedRewardDebt : userBalance.mul(pool.accumulatedLockedFatePerShare).div(1e12),
            isUpdated : true
        });

        // record deposit timestamp
        MembershipInfo memory membership = userMembershipInfo[_pid][msg.sender];
        if (membership.firstDepositTimestamp == 0) {
            // The user has not recorded a deposit yet;
            userMembershipInfo[_pid][msg.sender] = MembershipInfo({
                firstDepositTimestamp: block.timestamp,
                lastWithdrawTimestamp: block.timestamp
            });
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfoV3 storage pool = poolInfo[_pid];
        IFateRewardControllerV3.UserInfo memory user = _getUserInfo(_pid, msg.sender);
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);

        _claimRewards(_pid, msg.sender, user, pool);

        uint userBalance = user.amount.sub(_amount);
        _userInfo[_pid][msg.sender] = UserInfoV3({
            amount : userBalance,
            rewardDebt : userBalance.mul(pool.accumulatedFatePerShare).div(1e12),
            lockedRewardDebt : userBalance.mul(pool.accumulatedLockedFatePerShare).div(1e12),
            isUpdated : true
        });

        uint256 withdrawAmount = _reduceWithdrawalForFeesAndUpdateMembershipInfo(
            _pid,
            msg.sender,
            _amount,
            userBalance == 0
        );

        // send Fee to FeeTokenConverterToFate
        if (_amount > withdrawAmount) {
            uint256 feeAmount = _amount.sub(withdrawAmount);
            feeReserves[address(pool.lpToken)] = feeReserves[address(pool.lpToken)].add(feeAmount);
            pool.lpToken.transfer(fateFeeTo, feeAmount);
        }

        pool.lpToken.transfer(msg.sender, withdrawAmount);
        emit Withdraw(msg.sender, _pid, withdrawAmount);
    }

    function withdrawAll() public {
        for (uint i = 0; i < poolInfo.length; i++) {
            (uint amount,) = userInfo(i, msg.sender);
            if (amount > 0) {
                withdraw(i, amount);
            }
        }
    }

    function getEffectiveAmountAfterLpFee(
        uint256 _pid,
        address _account,
        uint256 _amount
    ) public view returns (uint256) {
        uint feeAmount = _amount.mul(getLPWithdrawFeePercent(_pid, _account)).div(10000);
        return _amount.sub(feeAmount);
    }

    function getEffectiveRewardAfterRewardFee(
        uint256 _pid,
        address _account,
        uint256 _reward
    ) public view returns (uint256) {
        return _reward.sub(_reward.mul(getLockedRewardsFeePercent(_pid, _account)).div(10000));
    }

    // Reduce LPWithdrawFee and record last withdraw timestamp
    function _reduceWithdrawalForFeesAndUpdateMembershipInfo(
        uint256 _pid,
        address _account,
        uint256 _amount,
        bool _withdrawAll
    ) internal returns (uint256) {
        if (_withdrawAll) {
            // record points earned and do not earn any more
            trackedPoints[_pid][_account] = trackedPoints[_pid][_account]
                .add(_getDurationInPosition(_pid, _account, true).mul(POINTS_PER_SECOND));
        }

        uint256 withdrawAmountAfterFee = getEffectiveAmountAfterLpFee(_pid, _account, _amount);
        userMembershipInfo[_pid][_account].lastWithdrawTimestamp = block.timestamp;
        if (_withdrawAll) {
            // reset the deposit timestamp
            userMembershipInfo[_pid][_account].firstDepositTimestamp = 0;
        }

        return withdrawAmountAfterFee;
    }

    function _claimRewards(
        uint256 _pid,
        address _user,
        IFateRewardControllerV3.UserInfo memory user,
        PoolInfoV3 memory pool
    ) internal {
        uint256 pendingUnlocked = user.amount
            .mul(pool.accumulatedFatePerShare)
            .div(1e12)
            .sub(user.rewardDebt);

        uint256 pendingLocked = user.amount
            .mul(pool.accumulatedLockedFatePerShare)
            .div(1e12)
            .sub(user.lockedRewardDebt);

        // implement fee reduction for rewards
        pendingUnlocked = getEffectiveRewardAfterRewardFee(_pid, _user, pendingUnlocked);
        pendingLocked = getEffectiveRewardAfterRewardFee(_pid, _user, pendingLocked);

        // recorded locked rewards
        userLockedRewards[_pid][_user] = userLockedRewards[_pid][_user].add(pendingLocked);

        _safeFateTransfer(_user, pendingUnlocked);
        emit ClaimRewards(_user, _pid, pendingUnlocked);
    }

    // claim any pending rewards from this pool, from msg.sender
    function claimReward(uint256 _pid) public {
        PoolInfoV3 storage pool = poolInfo[_pid];
        IFateRewardControllerV3.UserInfo memory user = _getUserInfo(_pid, msg.sender);
        updatePool(_pid);
        _claimRewards(_pid, msg.sender, user, pool);

        _userInfo[_pid][msg.sender] = UserInfoV3({
            amount : user.amount,
            rewardDebt : user.amount.mul(pool.accumulatedFatePerShare).div(1e12),
            lockedRewardDebt : user.amount.mul(pool.accumulatedLockedFatePerShare).div(1e12),
            isUpdated : true
        });
    }

    // claim any pending rewards from this pool, from msg.sender
    function claimRewards(uint256[] calldata _pids) external {
        for (uint i = 0; i < _pids.length; i++) {
            claimReward(_pids[i]);
        }
    }

    function setAllowEmergencyWithdrawal(bool _allowEmergencyWithdrawal) public onlyOwner {
        allowEmergencyWithdrawal = _allowEmergencyWithdrawal;
        emit EmergencyWithdrawalAllowedSet(_allowEmergencyWithdrawal);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        require(
            allowEmergencyWithdrawal,
            "emergency withdrawal not enabled"
        );

        PoolInfoV3 storage pool = poolInfo[_pid];
        IFateRewardControllerV3.UserInfo memory user = _getUserInfo(_pid, msg.sender);
        pool.lpToken.transfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);

        _userInfo[_pid][msg.sender] = UserInfoV3({
            amount : 0,
            rewardDebt : 0,
            lockedRewardDebt : 0,
            isUpdated : true
        });
    }

    // Safe fate transfer function, just in case if rounding error causes pool to not have enough FATEs.
    function _safeFateTransfer(address _to, uint256 _amount) internal {
        uint256 fateBal = fate.balanceOf(address(this));
        if (_amount > fateBal) {
            fate.transfer(_to, fateBal);
        } else {
            fate.transfer(_to, _amount);
        }
    }

    function setRewardSchedule(
        IRewardScheduleV3 _rewardSchedule
    )
    public
    onlyOwner {
        // pro-rate the pools to the current timestamp, before changing the schedule
        massUpdatePools();
        rewardSchedule = _rewardSchedule;
        emit RewardScheduleSet(address(_rewardSchedule));
    }

    function setVault(
        address _vault
    )
    public
    override
    onlyOwner {
        // pro-rate the pools to the current timestamp, before changing the schedule
        vault = _vault;
        emit VaultSet(_vault);
    }

    /// @dev calculate Points earned by this user
    function userPoints(uint256 _pid, address _user) public view returns (uint256){
        if (!isFatePool(_pid)) {
            return 0;
        } else {
            return POINTS_PER_SECOND
                .mul(_getDurationInPosition(_pid, _user, true))
                .add(trackedPoints[_pid][_user]);
        }
    }

    function allUserPoints(
        address _user
    ) public view returns (uint) {
        uint length = poolLength();
        uint points = 0;
        for (uint i = 0; i < length; i++) {
            points += userPoints(i, _user);
        }
        return points;
    }

    /// @dev check if pool is FatePool or not
    function isFatePool(uint _pid) internal view returns(bool) {
        return _pid < poolInfo.length && address(poolInfo[_pid].lpToken) != address(0);
    }
}
