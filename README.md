# TokenizedInsurancePool Smart Contract

## Overview

The `TokenizedInsurancePool` is a Solidity smart contract that enables users to create tokenized insurance policies using ERC20 tokens. Users pay premiums to receive coverage if an asset's price, sourced from a Chainlink price feed, falls below a specified threshold. The contract is designed to manage insurance policies securely, with features like risk-based premium calculations, solvency controls, oracle manipulation protection, and emergency pause functionality.

This contract is built with security and reliability in mind, leveraging OpenZeppelin's `Ownable`, `Pausable`, and `ReentrancyGuard` for access control, emergency handling, and protection against reentrancy attacks. It also uses `SafeERC20` for safe token interactions and Chainlink's `AggregatorV3Interface` for reliable price data.

## Key Features

- **Tokenized Insurance Policies**: Users pay premiums in an ERC20 token and receive coverage for asset price drops below a specified threshold.
- **Chainlink Price Feed Integration**: Uses Chainlink oracles to fetch reliable asset price data, with optional secondary oracle for verification.
- **Risk-Based Premiums**: Premiums are calculated based on coverage amount, price threshold proximity, policy duration, and a risk multiplier.
- **Solvency Controls**: Ensures the pool can cover claims by limiting total coverage based on the pool's balance and capital efficiency ratio.
- **Oracle Health Checks**: Validates oracle data for freshness and consistency, with configurable staleness thresholds and deviation checks.
- **Policy Expiration**: Policies have a defined duration, with automatic expiration after the set period.
- **Emergency Pause**: Allows the owner to pause the contract in emergencies, halting new policies and claims.
- **Keeper Functionality**: Supports batch policy expiration by an authorized keeper or owner.
- **Excess Funds Withdrawal**: Allows the owner to withdraw funds exceeding the amount needed to cover active policies.
- **Claim History Tracking**: Maintains a record of all processed claims for transparency and analytics.

## Contract Structure

### Dependencies
- **OpenZeppelin Contracts**:
  - `IERC20`: Interface for ERC20 token interactions.
  - `SafeERC20`: Safe handling of ERC20 token transfers.
  - `Ownable`: Ownership and access control.
  - `Pausable`: Emergency pause functionality.
  - `ReentrancyGuard`: Protection against reentrancy attacks.
- **Chainlink**:
  - `AggregatorV3Interface`: Interface for fetching price data from Chainlink oracles.

### Key Components
- **State Variables**:
  - `insuranceToken`: Immutable ERC20 token used for premiums and payouts.
  - `priceFeed`: Immutable primary Chainlink price feed.
  - `secondaryPriceFeed`: Optional secondary Chainlink price feed for verification.
  - `oracleDecimals`: Decimals used by the price feed.
  - `staleDataThreshold`: Maximum allowed delay for oracle data (default: 3 hours).
  - `maxOracleDeviation`: Maximum price deviation between primary and secondary oracles (default: 5%).
  - `capitalEfficiencyRatio`: Limits total coverage relative to pool balance (default: 3x).
  - `minPolicyDuration` and `maxPolicyDuration`: Policy duration constraints (default: 1 day to 365 days).
  - `riskMultiplier`: Adjusts premium calculations (default: 10).
  - `totalCoverageAmount`: Tracks total coverage of active policies.
  - `minPremium`: Minimum premium amount (default: 0.001 tokens with 18 decimals).
  - `policies`: Mapping of user addresses to their policy details.
  - `keeper`: Address authorized for batch operations.
  - `claimHistory`: Array of historical claim records.

- **Structs**:
  - `Policy`: Stores user policy details (user address, premium, coverage, price threshold, expiration, and status).
  - `ClaimRecord`: Stores claim history (user, amount, timestamp, and price at claim).

- **Events**:
  - Emits events for contract initialization, policy creation/expiration, claim processing, parameter updates, and more.

### Core Functions
- **Constructor**: Initializes the contract with the ERC20 token and primary Chainlink price feed.
- `setSecondaryOracle`: Sets an optional secondary oracle for price verification.
- `updateParameter`: Updates configurable parameters (e.g., `staleDataThreshold`, `riskMultiplier`).
- `setKeeper`: Sets the keeper address for batch operations.
- `pause` and `unpause`: Toggles contract pause state.
- `withdrawExcessFunds`: Withdraws excess funds not needed for active policies.
- `calculatePremium`: Calculates the premium based on coverage, price threshold, and duration.
- `createPolicy`: Creates a new insurance policy after premium payment.
- `processClaim`: Processes a claim if the price falls below the policy's threshold.
- `expirePolicy`: Expires a single policy if past its expiration timestamp.
- `batchExpirePolicies`: Expires multiple policies in a single transaction.
- `getCurrentPrice`: Fetches the current price from the primary oracle.
- `checkOracleHealth`: Validates oracle data reliability.
- `getPolicy`: Retrieves policy details for a user.
- `getProtocolMetrics`: Returns key metrics (e.g., total policies, pool balance).
- `getClaimHistoryCount`: Returns the number of historical claims.

## Usage

### Deployment
1. Deploy the contract with the following constructor arguments:
   - `_insuranceToken`: Address of the ERC20 token for premiums and payouts.
   - `_priceFeed`: Address of the Chainlink price feed (e.g., ETH/USD).
2. Ensure the token and price feed addresses are valid and compatible.

### Creating a Policy
1. **Approve Token Transfer**: Users must approve the contract to spend the required premium amount using the ERC20 token's `approve` function.
2. **Call `createPolicy`**:
   - `_coverageAmount`: Desired coverage amount (in token units).
   - `_priceThreshold`: Price level below which a claim can be triggered (in oracle decimals).
   - `_duration`: Policy duration in seconds (between `minPolicyDuration` and `maxPolicyDuration`).
3. The contract calculates the premium, checks solvency, and creates the policy if conditions are met.

### Processing a Claim
1. Users call `processClaim` to check if the asset price is below their policy's threshold.
2. The contract verifies:
   - Policy is active and not expired.
   - Oracle data is healthy (fresh and consistent).
   - Price is below the threshold.
3. If valid, the contract pays out the coverage amount (or a partial amount if the pool balance is insufficient).

### Expiring Policies
- Users or the keeper can call `expirePolicy` for a single policy or `batchExpirePolicies` for multiple policies if they are past their expiration timestamp.

### Owner Operations
- **Update Parameters**: Use `updateParameter` to adjust settings like `riskMultiplier` or `staleDataThreshold`.
- **Set Secondary Oracle**: Use `setSecondaryOracle` to add a secondary price feed for enhanced security.
- **Withdraw Funds**: Use `withdrawExcessFunds` to retrieve excess tokens not needed for active policies.
- **Pause/Unpause**: Use `pause` and `unpause` for emergency control.

### Monitoring
- Use `getProtocolMetrics` to retrieve key metrics like pool balance, active coverage, and oracle status.
- Use `getPolicy` to view a user's policy details.
- Use `getClaimHistoryCount` to track the number of processed claims.

## Security Considerations
- **Oracle Reliability**: The contract checks for stale data and price deviations to mitigate oracle manipulation risks.
- **Reentrancy Protection**: Uses `ReentrancyGuard` to prevent reentrancy attacks during token transfers.
- **Solvency Checks**: Limits total coverage to ensure the pool can cover claims.
- **Access Control**: Only the owner can update parameters, set the keeper, or withdraw funds.
- **Pause Mechanism**: Allows halting operations in case of vulnerabilities or oracle issues.
- **Safe Token Handling**: Uses `SafeERC20` to handle ERC20 token interactions safely.

## Events
The contract emits events for transparency and off-chain monitoring:
- `ContractInitialized`: When the contract is deployed.
- `PolicyCreated`: When a new policy is created.
- `PolicyExpired`: When a policy expires.
- `ClaimProcessed` and `PartialClaimProcessed`: When a claim is fully or partially paid.
- `ClaimFailed`: When a claim attempt fails.
- `ParametersUpdated`: When a parameter is updated.
- `KeeperUpdated`: When the keeper address changes.
- `SecondaryOracleUpdated`: When the secondary oracle is set.
- `FundsWithdrawn`: When excess funds are withdrawn.

## Requirements
- **Solidity Version**: `^0.8.20`
- **Dependencies**:
  - OpenZeppelin Contracts (`IERC20`, `SafeERC20`, `Ownable`, `Pausable`, `ReentrancyGuard`)
  - Chainlink Contracts (`AggregatorV3Interface`)
- **External Contracts**:
  - A standard ERC20 token for premiums and payouts.
  - A Chainlink price feed contract compatible with `AggregatorV3Interface`.

## Example Usage
```solidity
// Deploy the contract
TokenizedInsurancePool pool = new TokenizedInsurancePool(
    address(token), // ERC20 token address
    address(priceFeed) // Chainlink price feed address
);

// Approve tokens for premium payment
token.approve(address(pool), premiumAmount);

// Create a policy
pool.createPolicy(
    1000e18, // 1000 tokens coverage
    1500e8, // $1500 price threshold (assuming 8 decimals)
    30 days // Policy duration
);

// Process a claim
pool.processClaim();
```

## License
The contract is licensed under the MIT License, as specified by the SPDX identifier at the top of the contract.
