// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RaffleLendingProtocol
 * @notice A lending protocol where lenders earn rewards through raffles instead of fixed APY
 */
contract RaffleLendingProtocol is ReentrancyGuard, Ownable {
    
    // Structs
    struct Pool {
        address asset;
        uint256 totalDeposits;
        uint256 totalBorrows;
        uint256 utilizationRate; // Basis points (10000 = 100%)
        uint256 borrowRate; // Annual rate in basis points
        uint256 collateralFactor; // Required collateral ratio (10000 = 100%)
        bool isActive;
    }
    
    struct UserDeposit {
        uint256 amount;
        uint256 depositTime;
        uint256 raffleTickets; // Tickets earned for raffle
    }
    
    struct UserBorrow {
        uint256 amount;
        uint256 borrowTime;
        uint256 collateralAmount;
        address collateralAsset;
    }
    
    struct Raffle {
        uint256 id;
        uint256 totalRewardPool;
        uint256 endTime;
        uint256 numberOfWinners;
        address[] participants;
        mapping(address => uint256) ticketCount;
        address[] winners;
        bool drawn;
    }
    
    // State variables
    mapping(address => Pool) public pools;
    mapping(address => mapping(address => UserDeposit)) public userDeposits; // user => asset => deposit
    mapping(address => mapping(address => UserBorrow)) public userBorrows; // user => asset => borrow
    
    uint256 public raffleCounter;
    mapping(uint256 => Raffle) public raffles;
    uint256 public currentRaffleId;
    
    uint256 public constant RAFFLE_DURATION = 7 days;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant TICKETS_PER_TOKEN_DAY = 1; // 1 ticket per token per day deposited
    
    // Protocol fee (goes to raffle pool)
    uint256 public protocolFeeRate = 1000; // 10% of interest
    
    // Events
    event PoolCreated(address indexed asset, uint256 collateralFactor);
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 tickets);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);
    event Borrowed(address indexed user, address indexed asset, uint256 amount, address collateralAsset);
    event Repaid(address indexed user, address indexed asset, uint256 amount);
    event RaffleCreated(uint256 indexed raffleId, uint256 rewardPool, uint256 endTime);
    event RaffleDrawn(uint256 indexed raffleId, address[] winners, uint256 rewardPerWinner);
    
    constructor() {}
    
    // Admin functions
    function createPool(
        address asset,
        uint256 collateralFactor,
        uint256 borrowRate
    ) external onlyOwner {
        require(asset != address(0), "Invalid asset");
        require(!pools[asset].isActive, "Pool exists");
        require(collateralFactor >= BASIS_POINTS, "Collateral factor must be >= 100%");
        
        pools[asset] = Pool({
            asset: asset,
            totalDeposits: 0,
            totalBorrows: 0,
            utilizationRate: 0,
            borrowRate: borrowRate,
            collateralFactor: collateralFactor,
            isActive: true
        });
        
        emit PoolCreated(asset, collateralFactor);
    }
    
    function startNewRaffle(uint256 numberOfWinners) external onlyOwner {
        if (currentRaffleId > 0) {
            require(raffles[currentRaffleId].drawn, "Previous raffle not drawn");
        }
        
        raffleCounter++;
        currentRaffleId = raffleCounter;
        
        Raffle storage newRaffle = raffles[currentRaffleId];
        newRaffle.id = currentRaffleId;
        newRaffle.totalRewardPool = 0;
        newRaffle.endTime = block.timestamp + RAFFLE_DURATION;
        newRaffle.numberOfWinners = numberOfWinners;
        newRaffle.drawn = false;
        
        emit RaffleCreated(currentRaffleId, 0, newRaffle.endTime);
    }
    
    // User functions
    function deposit(address asset, uint256 amount) external nonReentrant {
        require(pools[asset].isActive, "Pool not active");
        require(amount > 0, "Amount must be > 0");
        
        Pool storage pool = pools[asset];
        UserDeposit storage userDeposit = userDeposits[msg.sender][asset];
        
        // Transfer tokens
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        
        // Calculate raffle tickets
        uint256 tickets = calculateRaffleTickets(amount, 0);
        
        // Update user deposit
        userDeposit.amount += amount;
        userDeposit.depositTime = block.timestamp;
        userDeposit.raffleTickets += tickets;
        
        // Update pool
        pool.totalDeposits += amount;
        _updateUtilization(asset);
        
        // Add to current raffle
        if (currentRaffleId > 0 && !raffles[currentRaffleId].drawn) {
            _addToRaffle(msg.sender, tickets);
        }
        
        emit Deposited(msg.sender, asset, amount, tickets);
    }
    
    function withdraw(address asset, uint256 amount) external nonReentrant {
        Pool storage pool = pools[asset];
        UserDeposit storage userDeposit = userDeposits[msg.sender][asset];
        
        require(userDeposit.amount >= amount, "Insufficient balance");
        require(pool.totalDeposits - pool.totalBorrows >= amount, "Insufficient liquidity");
        
        // Update user deposit
        userDeposit.amount -= amount;
        
        // Recalculate raffle tickets
        uint256 daysDeposited = (block.timestamp - userDeposit.depositTime) / 1 days;
        userDeposit.raffleTickets = calculateRaffleTickets(userDeposit.amount, daysDeposited);
        
        // Update pool
        pool.totalDeposits -= amount;
        _updateUtilization(asset);
        
        // Transfer tokens
        IERC20(asset).transfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, asset, amount);
    }
    
    function borrow(
        address borrowAsset,
        uint256 borrowAmount,
        address collateralAsset,
        uint256 collateralAmount
    ) external nonReentrant {
        Pool storage borrowPool = pools[borrowAsset];
        Pool storage collateralPool = pools[collateralAsset];
        
        require(borrowPool.isActive && collateralPool.isActive, "Pool not active");
        require(borrowAmount > 0, "Amount must be > 0");
        
        // Check collateral requirements
        uint256 requiredCollateral = (borrowAmount * collateralPool.collateralFactor) / BASIS_POINTS;
        require(collateralAmount >= requiredCollateral, "Insufficient collateral");
        
        // Check liquidity
        require(borrowPool.totalDeposits - borrowPool.totalBorrows >= borrowAmount, "Insufficient liquidity");
        
        // Transfer collateral
        IERC20(collateralAsset).transferFrom(msg.sender, address(this), collateralAmount);
        
        // Update user borrow
        UserBorrow storage userBorrow = userBorrows[msg.sender][borrowAsset];
        userBorrow.amount += borrowAmount;
        userBorrow.borrowTime = block.timestamp;
        userBorrow.collateralAmount += collateralAmount;
        userBorrow.collateralAsset = collateralAsset;
        
        // Update pool
        borrowPool.totalBorrows += borrowAmount;
        _updateUtilization(borrowAsset);
        
        // Transfer borrowed tokens
        IERC20(borrowAsset).transfer(msg.sender, borrowAmount);
        
        emit Borrowed(msg.sender, borrowAsset, borrowAmount, collateralAsset);
    }
    
    function repay(address asset, uint256 amount) external nonReentrant {
        Pool storage pool = pools[asset];
        UserBorrow storage userBorrow = userBorrows[msg.sender][asset];
        
        require(userBorrow.amount > 0, "No active borrow");
        
        // Calculate interest
        uint256 interest = calculateBorrowInterest(msg.sender, asset);
        uint256 totalDebt = userBorrow.amount + interest;
        
        require(amount <= totalDebt, "Amount exceeds debt");
        
        // Calculate protocol fee from interest
        uint256 protocolFee = (interest * protocolFeeRate) / BASIS_POINTS;
        
        // Add protocol fee to raffle pool
        if (currentRaffleId > 0 && !raffles[currentRaffleId].drawn) {
            raffles[currentRaffleId].totalRewardPool += protocolFee;
        }
        
        // Transfer repayment
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        
        // Update borrow
        uint256 principalRepaid = amount > interest ? amount - interest : 0;
        userBorrow.amount -= principalRepaid;
        
        // Return collateral proportionally
        if (userBorrow.amount == 0) {
            uint256 collateralToReturn = userBorrow.collateralAmount;
            userBorrow.collateralAmount = 0;
            IERC20(userBorrow.collateralAsset).transfer(msg.sender, collateralToReturn);
        } else {
            uint256 collateralToReturn = (userBorrow.collateralAmount * principalRepaid) / (userBorrow.amount + principalRepaid);
            userBorrow.collateralAmount -= collateralToReturn;
            IERC20(userBorrow.collateralAsset).transfer(msg.sender, collateralToReturn);
        }
        
        // Update pool
        pool.totalBorrows -= principalRepaid;
        _updateUtilization(asset);
        
        emit Repaid(msg.sender, asset, amount);
    }
    
    function drawRaffle(uint256 raffleId) external onlyOwner {
        Raffle storage raffle = raffles[raffleId];
        require(!raffle.drawn, "Already drawn");
        require(block.timestamp >= raffle.endTime, "Raffle not ended");
        require(raffle.participants.length > 0, "No participants");
        
        uint256 winnersCount = raffle.numberOfWinners;
        if (winnersCount > raffle.participants.length) {
            winnersCount = raffle.participants.length;
        }
        
        // Simple random selection (in production, use Chainlink VRF)
        uint256 totalTickets = 0;
        for (uint256 i = 0; i < raffle.participants.length; i++) {
            totalTickets += raffle.ticketCount[raffle.participants[i]];
        }
        
        for (uint256 i = 0; i < winnersCount; i++) {
            uint256 randomNumber = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, i))) % totalTickets;
            address winner = _selectWinner(raffleId, randomNumber);
            raffle.winners.push(winner);
        }
        
        raffle.drawn = true;
        
        // Distribute rewards
        uint256 rewardPerWinner = raffle.totalRewardPool / winnersCount;
        for (uint256 i = 0; i < raffle.winners.length; i++) {
            // In production, specify which asset to distribute
            // For now, this is a placeholder
        }
        
        emit RaffleDrawn(raffleId, raffle.winners, rewardPerWinner);
    }
    
    // View functions
    function getUserDepositInfo(address user, address asset) external view returns (uint256 amount, uint256 tickets) {
        UserDeposit memory deposit = userDeposits[user][asset];
        return (deposit.amount, deposit.raffleTickets);
    }
    
    function getUserBorrowInfo(address user, address asset) external view returns (
        uint256 amount,
        uint256 interest,
        uint256 collateralAmount,
        address collateralAsset
    ) {
        UserBorrow memory borrow = userBorrows[user][asset];
        uint256 calculatedInterest = calculateBorrowInterest(user, asset);
        return (borrow.amount, calculatedInterest, borrow.collateralAmount, borrow.collateralAsset);
    }
    
    function getRaffleInfo(uint256 raffleId) external view returns (
        uint256 rewardPool,
        uint256 endTime,
        uint256 participantCount,
        bool drawn
    ) {
        Raffle storage raffle = raffles[raffleId];
        return (raffle.totalRewardPool, raffle.endTime, raffle.participants.length, raffle.drawn);
    }
    
    function getRaffleWinners(uint256 raffleId) external view returns (address[] memory) {
        return raffles[raffleId].winners;
    }
    
    function calculateBorrowInterest(address user, address asset) public view returns (uint256) {
        UserBorrow memory borrow = userBorrows[user][asset];
        if (borrow.amount == 0) return 0;
        
        Pool memory pool = pools[asset];
        uint256 timeElapsed = block.timestamp - borrow.borrowTime;
        uint256 annualInterest = (borrow.amount * pool.borrowRate) / BASIS_POINTS;
        uint256 interest = (annualInterest * timeElapsed) / 365 days;
        
        return interest;
    }
    
    function calculateRaffleTickets(uint256 amount, uint256 daysDeposited) public pure returns (uint256) {
        return (amount * TICKETS_PER_TOKEN_DAY * (daysDeposited + 1)) / 1e18;
    }
    
    // Internal functions
    function _updateUtilization(address asset) internal {
        Pool storage pool = pools[asset];
        if (pool.totalDeposits == 0) {
            pool.utilizationRate = 0;
        } else {
            pool.utilizationRate = (pool.totalBorrows * BASIS_POINTS) / pool.totalDeposits;
        }
    }
    
    function _addToRaffle(address user, uint256 tickets) internal {
        Raffle storage raffle = raffles[currentRaffleId];
        
        if (raffle.ticketCount[user] == 0) {
            raffle.participants.push(user);
        }
        raffle.ticketCount[user] += tickets;
    }
    
    function _selectWinner(uint256 raffleId, uint256 randomNumber) internal view returns (address) {
        Raffle storage raffle = raffles[raffleId];
        uint256 cumulativeTickets = 0;
        
        for (uint256 i = 0; i < raffle.participants.length; i++) {
            address participant = raffle.participants[i];
            cumulativeTickets += raffle.ticketCount[participant];
            
            if (randomNumber < cumulativeTickets) {
                return participant;
            }
        }
        
        return raffle.participants[raffle.participants.length - 1];
    }
}
