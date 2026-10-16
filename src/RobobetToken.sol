// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Robobet (ROBOBET)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 ROBOBET (18 decimals) is minted
///         once, to the deployer, in the constructor. There is no owner, no mint, no pause, no
///         blacklist, no transfer tax and no upgrade path: after deployment nobody can change the
///         token's rules or touch a holder's balance.
/// @dev The deployer is the launch factory (`msg.sender` of the constructor), which distributes the
///      supply: 10% to the swarm's MerkleDistributor, 88% to the single-sided Uniswap v4 pool and
///      the remainder to the requester's wallet. Because transfers are untaxed, every launch flow
///      moves exactly what it says. `burn` and `burnFrom` are deliberately absent so the supply can
///      neither grow nor be reduced by anyone but a holder sending to an address they do not control.
contract RobobetToken is ERC20 {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "Robobet";
    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "ROBOBET";
    /// @notice Number of decimals; the ERC-20 default of 18.
    uint8 public constant DECIMALS = 18;
    /// @notice The whole supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Emitted once, from the constructor, recording who received the full supply.
    /// @param deployer The address the whole supply was minted to (`msg.sender` of the deployment).
    /// @param supply The amount minted, equal to `TOTAL_SUPPLY`.
    event SupplyMinted(address indexed deployer, uint256 supply);

    /// @notice Mints the whole supply to the deployer. Takes no arguments and calls no other contract,
    ///         so it can run on an empty chain.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
