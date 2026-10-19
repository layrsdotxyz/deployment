// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

interface IZenStaker {
    function STAKE_TOKEN() external view returns (address);
    function REWARD_TOKEN() external view returns (address);

    function stake(uint256 amount, address delegatee, address claimer)
        external
        returns (uint256 depositId);

    function stakeMore(uint256 depositId, uint256 amount) external;
    function withdraw(uint256 depositId, uint256 amount) external;
    function alterDelegatee(uint256 depositId, address newDelegatee) external;

    function claimReward(uint256 depositId) external returns (uint256);
    function unclaimedReward(uint256 depositId) external view returns (uint256);
}

contract ZenStakerAdapter is Ownable, ReentrancyGuard, IYieldAdapter {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error ZeroAmount();
    error RewardTokenMismatch(address stakeToken, address rewardToken);
    error InvalidRewardToken(address rewardToken);
    error NoDeposit();
    error UnauthorizedDelegateeManager();

    address public immutable override asset;
    address public immutable rewardToken;
    IZenStaker public immutable zenStaker;
    address public immutable delegateeManager;
    address public delegatee;
    string private _name;

    uint256 public depositId;
    bool public depositCreated;
    uint256 public accountedStaked;

    event YieldCompounded(uint256 rewardAmount, uint256 totalDeployed);
    event YieldCompoundSkipped();
    event DelegateeUpdated(address indexed oldDelegatee, address indexed newDelegatee);

    constructor(
        address pool_,
        address zenStaker_,
        address delegatee_,
        address delegateeManager_,
        string memory name_
    ) Ownable(pool_) {
        if (pool_       == address(0)) revert ZeroAddress();
        if (zenStaker_  == address(0)) revert ZeroAddress();
        if (delegatee_  == address(0)) revert ZeroAddress();
        if (delegateeManager_ == address(0)) revert ZeroAddress();

        IZenStaker z = IZenStaker(zenStaker_);
        address stakeToken = z.STAKE_TOKEN();
        address rewards    = z.REWARD_TOKEN();
        if (stakeToken == address(0)) revert ZeroAddress();
        if (rewards    == address(0)) revert ZeroAddress();
        if (stakeToken != rewards)    revert RewardTokenMismatch(stakeToken, rewards);

        asset      = stakeToken;
        rewardToken = rewards;
        zenStaker = z;
        delegateeManager = delegateeManager_;
        delegatee = delegatee_;
        _name     = name_;
    }

    function pool() external view override returns (address) {
        return owner();
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function setDelegatee(address newDelegatee) external nonReentrant {
        if (msg.sender != delegateeManager) revert UnauthorizedDelegateeManager();
        if (newDelegatee == address(0)) revert ZeroAddress();
        address oldDelegatee = delegatee;
        if (depositCreated) {
            zenStaker.alterDelegatee(depositId, newDelegatee);
        }
        delegatee = newDelegatee;
        emit DelegateeUpdated(oldDelegatee, newDelegatee);
    }

    function deposit(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _compoundBestEffort();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(zenStaker), amount);

        uint256 beforeStake = IERC20(asset).balanceOf(address(this));
        if (depositCreated) {
            zenStaker.stakeMore(depositId, amount);
        } else {
            depositId = zenStaker.stake(amount, delegatee, address(this));
            depositCreated = true;
        }
        accountedStaked += beforeStake - IERC20(asset).balanceOf(address(this));

        emit YieldDeposited(amount, deposited());
    }

    function withdraw(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!depositCreated) revert NoDeposit();

        _compoundBestEffort();

        uint256 received;

        uint256 idle = IERC20(asset).balanceOf(address(this));
        if (idle != 0) {
            uint256 fromIdle = idle > amount ? amount : idle;
            IERC20(asset).safeTransfer(owner(), fromIdle);
            received += fromIdle;
            amount -= fromIdle;
        }

        if (amount != 0) {
            uint256 toWithdraw = amount > accountedStaked ? accountedStaked : amount;
            if (toWithdraw != 0) {
                uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
                zenStaker.withdraw(depositId, toWithdraw);
                accountedStaked -= toWithdraw;
                uint256 withdrawn = IERC20(asset).balanceOf(address(this)) - beforeBalance;
                IERC20(asset).safeTransfer(owner(), withdrawn);
                received += withdrawn;
            }
        }

        emit YieldWithdrawn(received, deposited());
    }

    function sync() external view override onlyOwner returns (uint256) {
        return deposited();
    }

    function compound() external nonReentrant returns (uint256) {
        return _compound();
    }

    function claimRewards(address rewardToken_, bytes calldata) external override onlyOwner nonReentrant {
        if (rewardToken_ != rewardToken) revert InvalidRewardToken(rewardToken_);
        _compound();
    }

    function deposited() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + accountedStaked;
    }

    function _compound() internal returns (uint256 compounded) {
        if (!depositCreated) return 0;

        uint256 claimable = zenStaker.unclaimedReward(depositId);
        if (claimable == 0) return 0;

        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        zenStaker.claimReward(depositId);
        compounded = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        if (compounded == 0) return 0;

        IERC20(asset).forceApprove(address(zenStaker), compounded);
        uint256 beforeStake = IERC20(asset).balanceOf(address(this));
        zenStaker.stakeMore(depositId, compounded);
        accountedStaked += beforeStake - IERC20(asset).balanceOf(address(this));

        emit YieldCompounded(compounded, deposited());
    }

    function _compoundBestEffort() internal returns (uint256 compounded) {
        if (!depositCreated) return 0;

        uint256 claimable;
        try zenStaker.unclaimedReward(depositId) returns (uint256 amount) {
            claimable = amount;
        } catch {
            emit YieldCompoundSkipped();
            return 0;
        }
        if (claimable == 0) return 0;

        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        try zenStaker.claimReward(depositId) returns (uint256) {
            compounded = IERC20(asset).balanceOf(address(this)) - beforeBalance;
        } catch {
            emit YieldCompoundSkipped();
            return 0;
        }
        if (compounded == 0) return 0;

        IERC20(asset).forceApprove(address(zenStaker), compounded);
        uint256 beforeStake = IERC20(asset).balanceOf(address(this));
        try zenStaker.stakeMore(depositId, compounded) {
            accountedStaked += beforeStake - IERC20(asset).balanceOf(address(this));
            emit YieldCompounded(compounded, deposited());
        } catch {
            IERC20(asset).forceApprove(address(zenStaker), 0);
            emit YieldCompoundSkipped();
            return 0;
        }
    }
}
