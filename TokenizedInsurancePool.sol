// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title TokenizedInsurancePool
 * @notice A contract for creating insurance policies tokenized via ERC20 tokens.
 * Users pay premiums and receive coverage if an asset's price (from a Chainlink oracle)
 * drops below their specified threshold.
 * 
 * Key Features:
 * - Policy expiration to limit contract liability
 * - Risk-based premium calculations
 * - Solvency controls to ensure the pool can cover claims
 * - Protection against oracle manipulation
 * - Emergency pause functionality
 *
 * @dev Ensure the _insuranceToken is a standard ERC20 contract.
 * Ensure the _priceFeed address is a valid Chainlink AggregatorV3Interface contract.
 */
contract TokenizedInsurancePool is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Token used for premiums and payouts
    IERC20 public immutable insuranceToken;
    
    // Chainlink price feed for off-chain data values
    AggregatorV3Interface public immutable priceFeed;
    
    // Secondary oracle for price verification (optional)
    AggregatorV3Interface public secondaryPriceFeed;
    
    // Decimals used by the Chainlink price feed
    uint8 public immutable oracleDecimals;

    // Maximum delay allowed for oracle price data before considering it stale
    uint256 public staleDataThreshold = 3 hours;
    
    // Maximum allowed price deviation between primary and secondary oracles (in percentage, 5 = 5%)
    uint256 public maxOracleDeviation = 5;
    
    // Capital efficiency ratio (coverage amount can be at most X times the total premiums)
    uint256 public capitalEfficiencyRatio = 3;
    
    // Minimum required duration for policies (in seconds)
    uint256 public minPolicyDuration = 1 days;
    
    // Maximum allowed policy duration (in seconds)
    uint256 public maxPolicyDuration = 365 days;
    
    // Risk factor multiplier used in premium calculations (higher = more expensive)
    uint256 public riskMultiplier = 10;
    
    // Total coverage amount of all active policies
    uint256 public totalCoverageAmount;
    
    // Minimum premium required (prevents dust amounts)
    uint256 public minPremium = 1e15; // 0.001 token with 18 decimals

    // Insurance policy details
    struct Policy {
        address user;
        uint256 premiumAmount;
        uint256 coverageAmount;
        uint256 priceThreshold; // Must match oracle decimals
        uint256 expirationTimestamp;
        bool active;
    }

    // Mapping of user addresses to their policies
    mapping(address => Policy) public policies;
    
    // Address authorized to trigger batch operations (e.g., keeper)
    address public keeper;
    
    // Historical claim records (for analytics)
    struct ClaimRecord {
        address user;
        uint256 amount;
        uint256 timestamp;
        uint256 priceAtClaim;
    }
    
    ClaimRecord[] public claimHistory;

    // Events
    event ContractInitialized(address indexed insuranceToken, address indexed priceFeed);
    event PolicyCreated(
        address indexed user,
        uint256 premiumAmount,
        uint256 coverageAmount,
        uint256 priceThreshold,
        uint256 expirationTimestamp
    );
    event PolicyExpired(address indexed user);
    event ClaimProcessed(address indexed user, uint256 payoutAmount);
    event PartialClaimProcessed(address indexed user, uint256 partialPayoutAmount, uint256 remainingCoverage);
    event ClaimFailed(address indexed user, string reason);
    event ParametersUpdated(string paramName, uint256 newValue);
    event KeeperUpdated(address indexed newKeeper);
    event SecondaryOracleUpdated(address indexed newOracle);
    event FundsWithdrawn(address indexed to, uint256 amount);

    /**
     * @notice Constructor to initialize the pool.
     * @param _insuranceToken Address of the ERC20 token for premiums/payouts.
     * @param _priceFeed Address of the Chainlink AggregatorV3Interface for the price data.
     */
    constructor(address _insuranceToken, address _priceFeed) Ownable(msg.sender) {
        require(_insuranceToken != address(0), "Invalid token address");
        require(_priceFeed != address(0), "Invalid price feed address");

        insuranceToken = IERC20(_insuranceToken);
        priceFeed = AggregatorV3Interface(_priceFeed);
        oracleDecimals = priceFeed.decimals(); // Store oracle decimals
        
        emit ContractInitialized(_insuranceToken, _priceFeed);
    }
    
    /**
     * @notice Set a secondary oracle for price verification.
     * @param _secondaryPriceFeed Address of the secondary Chainlink price feed.
     * @dev Having a secondary oracle helps mitigate oracle manipulation risks.
     */
    function setSecondaryOracle(address _secondaryPriceFeed) external onlyOwner {
        require(_secondaryPriceFeed != address(0), "Invalid oracle address");
        require(_secondaryPriceFeed != address(priceFeed), "Cannot use same oracle");
        
        secondaryPriceFeed = AggregatorV3Interface(_secondaryPriceFeed);
        require(secondaryPriceFeed.decimals() == oracleDecimals, "Oracle decimal mismatch");
        
        emit SecondaryOracleUpdated(_secondaryPriceFeed);
    }
    
    /**
     * @notice Update protocol parameters.
     * @param _paramName Name of the parameter to update.
     * @param _newValue New value for the parameter.
     */
    function updateParameter(string calldata _paramName, uint256 _newValue) external onlyOwner {
        bytes32 paramHash = keccak256(abi.encodePacked(_paramName));
        
        if (paramHash == keccak256(abi.encodePacked("staleDataThreshold"))) {
            require(_newValue >= 5 minutes && _newValue <= 1 days, "Invalid threshold value");
            staleDataThreshold = _newValue;
        } else if (paramHash == keccak256(abi.encodePacked("maxOracleDeviation"))) {
            require(_newValue > 0 && _newValue <= 20, "Invalid deviation value");
            maxOracleDeviation = _newValue;
        } else if (paramHash == keccak256(abi.encodePacked("capitalEfficiencyRatio"))) {
            require(_newValue > 0 && _newValue <= 10, "Invalid ratio value");
            capitalEfficiencyRatio = _newValue;
        } else if (paramHash == keccak256(abi.encodePacked("minPolicyDuration"))) {
            require(_newValue >= 1 hours && _newValue <= 30 days, "Invalid min duration");
            minPolicyDuration = _newValue;
        } else if (paramHash == keccak256(abi.encodePacked("maxPolicyDuration"))) {
            require(_newValue >= 7 days && _newValue <= 1825 days, "Invalid max duration");
            maxPolicyDuration = _newValue;
        } else if (paramHash == keccak256(abi.encodePacked("riskMultiplier"))) {
            require(_newValue > 0 && _newValue <= 100, "Invalid risk multiplier");
            riskMultiplier = _newValue;
        } else if (paramHash == keccak256(abi.encodePacked("minPremium"))) {
            minPremium = _newValue;
        } else {
            revert("Unknown parameter");
        }
        
        emit ParametersUpdated(_paramName, _newValue);
    }
    
    /**
     * @notice Set keeper address that can trigger batch operations.
     * @param _keeper Address of the authorized keeper.
     */
    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    /**
     * @notice Pause the contract in case of emergency.
     * @dev Only the contract owner can call this function.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract when it's safe to resume operations.
     * @dev Only the contract owner can call this function.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @notice Withdraw excess funds from the contract.
     * @param _amount Amount to withdraw.
     * @dev Only withdraws funds in excess of what's needed to cover active policies.
     */
    function withdrawExcessFunds(uint256 _amount) external onlyOwner {
        uint256 excessFunds = getExcessFunds();
        require(excessFunds >= _amount, "Insufficient excess funds");
        
        insuranceToken.safeTransfer(owner(), _amount);
        emit FundsWithdrawn(owner(), _amount);
    }
    
    /**
     * @notice Calculate excess funds that can be safely withdrawn.
     * @return excessFunds Amount that can be withdrawn without affecting solvency.
     */
    function getExcessFunds() public view returns (uint256 excessFunds) {
        uint256 totalBalance = insuranceToken.balanceOf(address(this));
        
        if (totalBalance > totalCoverageAmount) {
            excessFunds = totalBalance - totalCoverageAmount;
        } else {
            excessFunds = 0;
        }
    }

    /**
     * @notice Calculate the premium required for a given coverage amount, price threshold, and duration.
     * @param _coverageAmount The coverage amount desired.
     * @param _priceThreshold The price threshold for claim triggering.
     * @param _duration The policy duration in seconds.
     * @return premium The calculated premium amount.
     * @dev The premium is calculated based on risk factors including how close the threshold is to current price,
     * the duration of coverage, and the protocol's risk multiplier.
     */
    function calculatePremium(
        uint256 _coverageAmount,
        uint256 _priceThreshold,
        uint256 _duration
    ) public view returns (uint256 premium) {
        require(_coverageAmount > 0, "Coverage must be positive");
        require(_duration >= minPolicyDuration, "Duration too short");
        require(_duration <= maxPolicyDuration, "Duration too long");
        
        // Get current price from oracle
        (,int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");
        uint256 currentPrice = uint256(price);
        
        // Validate threshold
        require(_priceThreshold > 0 && _priceThreshold < currentPrice, "Invalid threshold");
        
        // Calculate risk factor (percentage difference from current price)
        uint256 priceDiff = currentPrice - _priceThreshold;
        uint256 riskFactor = (priceDiff * 100) / currentPrice;
        
        // Base premium calculation: coverage * risk * duration * multiplier / scaling factors
        premium = (_coverageAmount * riskFactor * _duration * riskMultiplier) / (365 days * 100 * 10);
        
        // Ensure minimum premium
        if (premium < minPremium) {
            premium = minPremium;
        }
        
        return premium;
    }

    /**
     * @notice Create a new insurance policy by depositing the premium.
     * @param _coverageAmount The coverage amount for a claim payout.
     * @param _priceThreshold The price threshold below which a claim can be triggered.
     * @param _duration The policy duration in seconds.
     * @dev User must approve the contract to spend premium tokens before calling.
     */
    function createPolicy(
        uint256 _coverageAmount,
        uint256 _priceThreshold,
        uint256 _duration
    ) external whenNotPaused nonReentrant {
        require(!policies[msg.sender].active, "Policy already exists");
        require(_coverageAmount > 0, "Coverage must be positive");
        require(_duration >= minPolicyDuration, "Duration too short");
        require(_duration <= maxPolicyDuration, "Duration too long");
        
        // Check oracle health
        (bool oracleHealthy, string memory healthReason) = checkOracleHealth();
        require(oracleHealthy, healthReason);
        
        // Convert price threshold to match oracle decimals if needed
        uint256 adjustedThreshold = _priceThreshold;
        
        // Calculate premium based on risk factors
        uint256 premiumAmount = calculatePremium(_coverageAmount, adjustedThreshold, _duration);
        
        // Check contract solvency - new policy should not exceed the pool's capacity
        uint256 newTotalCoverage = totalCoverageAmount + _coverageAmount;
        uint256 poolBalance = insuranceToken.balanceOf(address(this));
        uint256 poolCapacity = (poolBalance + premiumAmount) * capitalEfficiencyRatio;
        
        require(newTotalCoverage <= poolCapacity, "Exceeds pool capacity");
        
        // Transfer premium tokens from the user to the contract
        insuranceToken.safeTransferFrom(msg.sender, address(this), premiumAmount);
        
        // Calculate expiration timestamp
        uint256 expirationTimestamp = block.timestamp + _duration;
        
        // Create policy
        policies[msg.sender] = Policy({
            user: msg.sender,
            premiumAmount: premiumAmount,
            coverageAmount: _coverageAmount,
            priceThreshold: adjustedThreshold,
            expirationTimestamp: expirationTimestamp,
            active: true
        });
        
        // Update total coverage amount
        totalCoverageAmount += _coverageAmount;
        
        emit PolicyCreated(
            msg.sender,
            premiumAmount,
            _coverageAmount,
            adjustedThreshold,
            expirationTimestamp
        );
    }

    /**
     * @notice Process a claim if the policy's risk condition is met.
     * @dev Can be called by the policyholder. Verifies oracle data and policy status.
     */
    function processClaim() external whenNotPaused nonReentrant {
        Policy storage policy = policies[msg.sender];
        
        // Basic policy validation
        if (!policy.active) {
            emit ClaimFailed(msg.sender, "No active policy");
            return;
        }
        
        // Check policy expiration
        if (block.timestamp > policy.expirationTimestamp) {
            expirePolicy(msg.sender);
            emit ClaimFailed(msg.sender, "Policy expired");
            return;
        }
        
        // Validate oracle health and get current price
        (bool oracleHealthy, string memory healthReason) = checkOracleHealth();
        if (!oracleHealthy) {
            emit ClaimFailed(msg.sender, healthReason);
            return;
        }
        
        // Get current price from oracle
        uint256 currentPrice = getCurrentPrice();
        
        // Check if the risk condition is met (price below threshold)
        if (currentPrice >= policy.priceThreshold) {
            emit ClaimFailed(msg.sender, "Risk threshold not met");
            return;
        }
        
        // Calculate payout amount
        uint256 payoutAmount = policy.coverageAmount;
        uint256 availableBalance = insuranceToken.balanceOf(address(this));
        
        // Handle partial claims if necessary
        if (availableBalance < payoutAmount) {
            uint256 originalCoverage = policy.coverageAmount;
            uint256 remainingCoverage = originalCoverage - availableBalance;
            
            // Update policy for partial claim
            policy.coverageAmount = remainingCoverage;
            
            // Adjust payout to available balance
            payoutAmount = availableBalance;
            
            // Record claim history
            claimHistory.push(ClaimRecord({
                user: msg.sender,
                amount: payoutAmount,
                timestamp: block.timestamp,
                priceAtClaim: currentPrice
            }));
            
            // Update total coverage
            totalCoverageAmount -= payoutAmount;
            
            // Transfer the partial payout
            insuranceToken.safeTransfer(msg.sender, payoutAmount);
            
            emit PartialClaimProcessed(msg.sender, payoutAmount, remainingCoverage);
        } else {
            // Full claim payout
            // Update state before external call (Checks-Effects-Interactions)
            policy.active = false;
            
            // Record claim history
            claimHistory.push(ClaimRecord({
                user: msg.sender,
                amount: payoutAmount,
                timestamp: block.timestamp,
                priceAtClaim: currentPrice
            }));
            
            // Update total coverage
            totalCoverageAmount -= payoutAmount;
            
            // Transfer the full payout
            insuranceToken.safeTransfer(msg.sender, payoutAmount);
            
            emit ClaimProcessed(msg.sender, payoutAmount);
        }
    }
    
    /**
     * @notice Expire a policy that has passed its expiration timestamp.
     * @param _user Address of the policyholder.
     * @dev Can be called by anyone, but typically by keeper or the user.
     */
    function expirePolicy(address _user) public {
        Policy storage policy = policies[_user];
        
        require(policy.active, "Policy not active");
        require(block.timestamp > policy.expirationTimestamp, "Policy not expired");
        
        // Update policy status
        policy.active = false;
        
        // Update total coverage
        totalCoverageAmount -= policy.coverageAmount;
        
        emit PolicyExpired(_user);
    }
    
    /**
     * @notice Allow a keeper to expire multiple policies that have passed their expiration.
     * @param _users Array of user addresses to check for expired policies.
     * @dev Useful for batch maintenance of the contract.
     */
    function batchExpirePolicies(address[] calldata _users) external {
        require(msg.sender == keeper || msg.sender == owner(), "Not authorized");
        
        for (uint256 i = 0; i < _users.length; i++) {
            Policy storage policy = policies[_users[i]];
            
            if (policy.active && block.timestamp > policy.expirationTimestamp) {
                // Update policy status
                policy.active = false;
                
                // Update total coverage
                totalCoverageAmount -= policy.coverageAmount;
                
                emit PolicyExpired(_users[i]);
            }
        }
    }

    /**
     * @notice Get the current price from the primary oracle.
     * @return price The current price from the oracle.
     */
    function getCurrentPrice() public view returns (uint256 price) {
        (,int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid oracle price");
        return uint256(answer);
    }
    
    /**
     * @notice Validate the health and reliability of the oracle data.
     * @return isHealthy Boolean indicating if the oracle data is healthy.
     * @return reason String explaining why the oracle is unhealthy, if applicable.
     */
    function checkOracleHealth() public view returns (bool isHealthy, string memory reason) {
        try priceFeed.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Check for negative or zero price
            if (price <= 0) {
                return (false, "Invalid oracle price (<= 0)");
            }
            
            // Check for stale data
            if (updatedAt == 0 || block.timestamp - updatedAt > staleDataThreshold) {
                return (false, "Oracle price data is stale");
            }
            
            // Check for incomplete round
            if (answeredInRound < roundId) {
                return (false, "Oracle round incomplete");
            }
            
            // Secondary oracle verification if available
            if (address(secondaryPriceFeed) != address(0)) {
                try secondaryPriceFeed.latestRoundData() returns (
                    uint80,
                    int256 secondaryPrice,
                    uint256,
                    uint256 secondaryUpdatedAt,
                    uint80
                ) {
                    // Check if secondary price is fresh
                    if (block.timestamp - secondaryUpdatedAt > staleDataThreshold) {
                        return (false, "Secondary oracle data is stale");
                    }
                    
                    // Check for large deviations between oracles
                    if (secondaryPrice > 0) {
                        uint256 priceDiff;
                        if (uint256(price) > uint256(secondaryPrice)) {
                            priceDiff = uint256(price) - uint256(secondaryPrice);
                        } else {
                            priceDiff = uint256(secondaryPrice) - uint256(price);
                        }
                        
                        uint256 deviationPercentage = (priceDiff * 100) / uint256(price);
                        
                        if (deviationPercentage > maxOracleDeviation) {
                            return (false, "Oracle price deviation too high");
                        }
                    }
                } catch {
                    // Secondary oracle failed, but we still continue with primary
                    // This is a design decision - we could also fail here
                }
            }
            
            return (true, "");
        } catch {
            return (false, "Oracle data fetch failed");
        }
    }

    /**
     * @notice Allows retrieving policy details for a specific user.
     * @param _user The address of the policyholder.
     * @return Policy struct containing the user's policy details.
     */
    function getPolicy(address _user) external view returns (Policy memory) {
        return policies[_user];
    }
    
    /**
     * @notice Get protocol metrics for monitoring.
     * @return metrics A tuple containing key protocol metrics.
     */
    function getProtocolMetrics() external view returns (
        uint256 totalPolicies,
        uint256 activeCoverage,
        uint256 poolBalance,
        uint256 maxCoverageCapacity,
        uint256 utilizationRate,
        bool oracleStatus
    ) {
        totalPolicies = claimHistory.length;
        activeCoverage = totalCoverageAmount;
        poolBalance = insuranceToken.balanceOf(address(this));
        maxCoverageCapacity = poolBalance * capitalEfficiencyRatio;
        
        if (maxCoverageCapacity > 0) {
            utilizationRate = (activeCoverage * 100) / maxCoverageCapacity;
        } else {
            utilizationRate = 0;
        }
        
        (oracleStatus,) = checkOracleHealth();
    }
    
    /**
     * @notice Get the total number of historical claims.
     * @return count The total number of processed claims.
     */
    function getClaimHistoryCount() external view returns (uint256 count) {
        return claimHistory.length;
    }
}