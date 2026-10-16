// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Drives the token with random, bounded call sequences from several actors and keeps ghost
///         accounting of what every tracked address should hold and be allowed to spend.
/// @dev The handler is the deployer: it constructs the token, so it starts with the whole supply and
///      plays the factory's role. Four EOAs and the token contract itself (a sink: nothing can recover
///      what is sent there) are the other tracked holders. Every handler function asserts the exact
///      outcome of its call, success or the exact revert, so the invariant run is configured to fail
///      on any revert the handler did not expect.
contract RobobetHandler is CommonBase, StdCheats, StdUtils {
    RobobetToken public immutable token;
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    address[] public holders;
    mapping(address => bool) public isHolder;

    mapping(address => uint256) public ghost_balance;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    mapping(address => uint256) public ghost_received;
    mapping(address => uint256) public ghost_sent;

    uint256 public ghost_transfers;
    uint256 public ghost_transferFroms;
    uint256 public ghost_expectedReverts;
    uint256 public ghost_adminAttempts;
    uint256 public ghost_sunk;

    constructor() {
        token = new RobobetToken();
        _track(address(this));
        _track(address(0xA11CE));
        _track(address(0xB0B));
        _track(address(0xCA201));
        _track(address(0xDA4E));
        _track(address(token));
        ghost_balance[address(this)] = SUPPLY;
        ghost_received[address(this)] = SUPPLY;
    }

    function _track(address a) internal {
        holders.push(a);
        isHolder[a] = true;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    /// @dev Maps a fuzzed seed onto the actors that may send: every tracked address but the token
    ///      contract, which has no key and can never initiate a call.
    function _actor(uint256 seed) internal view returns (address) {
        return holders[bound(seed, 0, holders.length - 2)];
    }

    /// @dev Any tracked address, including the token contract, may receive.
    function _receiver(uint256 seed) internal view returns (address) {
        return holders[bound(seed, 0, holders.length - 1)];
    }

    function _recordMove(address from, address to, uint256 amount) internal {
        ghost_balance[from] -= amount;
        ghost_balance[to] += amount;
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
        if (to == address(token)) ghost_sunk += amount;
    }

    // ----------------------------------------------------------------------------------------
    // transfer
    // ----------------------------------------------------------------------------------------

    /// @notice A transfer the sender can afford always succeeds and moves exactly `amount`.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        require(ok, "transfer returned false");

        if (from == to) {
            require(token.balanceOf(from) == fromBefore, "self-transfer changed balance");
        } else {
            require(token.balanceOf(from) == fromBefore - amount, "sender debited wrong amount");
            require(token.balanceOf(to) == toBefore + amount, "receiver credited wrong amount");
        }
        _recordMove(from, to, amount);
        ghost_transfers++;
    }

    /// @notice An unbounded transfer: it must revert with the exact insufficient-balance error when and
    ///         only when `amount` exceeds the balance, and move exactly `amount` otherwise.
    function transferUnbounded(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        uint256 balance = token.balanceOf(from);

        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            require(ok, "transfer returned false");
            require(amount <= balance, "transfer above balance succeeded");
            _recordMove(from, to, amount);
            ghost_transfers++;
        } catch (bytes memory reason) {
            require(amount > balance, "affordable transfer reverted");
            require(
                keccak256(reason)
                    == keccak256(
                        abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount)
                    ),
                "wrong revert reason"
            );
            require(token.balanceOf(from) == balance, "a reverted transfer changed the balance");
            ghost_expectedReverts++;
        }
    }

    /// @notice Sending to the zero address always reverts, whatever the amount or sender.
    function transferToZero(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        try token.transfer(address(0), amount) {
            revert("transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))),
                "wrong revert reason"
            );
            ghost_expectedReverts++;
        }
    }

    // ----------------------------------------------------------------------------------------
    // approve / transferFrom
    // ----------------------------------------------------------------------------------------

    /// @notice Approvals overwrite; they never accumulate, and they never touch balances.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(owner);
        require(token.approve(spender, amount), "approve returned false");
        require(token.allowance(owner, spender) == amount, "allowance was not overwritten");
        require(token.balanceOf(owner) == ownerBefore, "approve moved a balance");
        ghost_allowance[owner][spender] = amount;
    }

    /// @notice Approving the zero spender always reverts and leaves no allowance behind.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            revert("approve of the zero spender succeeded");
        } catch (bytes memory reason) {
            require(
                keccak256(reason)
                    == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))),
                "wrong revert reason"
            );
            require(token.allowance(owner, address(0)) == 0, "zero spender has an allowance");
            ghost_expectedReverts++;
        }
    }

    /// @notice A transferFrom within both the allowance and the balance always succeeds, moves exactly
    ///         `amount`, and decrements the allowance unless it is infinite.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _receiver(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        amount = bound(amount, 0, allowed < balance ? allowed : balance);

        vm.prank(spender);
        require(token.transferFrom(owner, to, amount), "transferFrom returned false");

        uint256 expectedAllowance = allowed == type(uint256).max ? allowed : allowed - amount;
        require(token.allowance(owner, spender) == expectedAllowance, "allowance decremented wrongly");
        ghost_allowance[owner][spender] = expectedAllowance;
        _recordMove(owner, to, amount);
        ghost_transferFroms++;
    }

    /// @notice An unbounded transferFrom: the allowance is checked before the balance, each with its
    ///         exact error, and nothing changes on a revert.
    function transferFromUnbounded(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) public {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _receiver(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            require(ok, "transferFrom returned false");
            require(amount <= allowed && amount <= balance, "transferFrom beyond allowance or balance succeeded");
            uint256 expectedAllowance = allowed == type(uint256).max ? allowed : allowed - amount;
            require(token.allowance(owner, spender) == expectedAllowance, "allowance decremented wrongly");
            ghost_allowance[owner][spender] = expectedAllowance;
            _recordMove(owner, to, amount);
            ghost_transferFroms++;
        } catch (bytes memory reason) {
            bytes memory expected;
            if (amount > allowed) {
                expected =
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
            } else {
                require(amount > balance, "affordable, allowed transferFrom reverted");
                expected =
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
            }
            require(keccak256(reason) == keccak256(expected), "wrong revert reason");
            require(token.allowance(owner, spender) == allowed, "a reverted transferFrom changed the allowance");
            require(token.balanceOf(owner) == balance, "a reverted transferFrom changed the balance");
            ghost_expectedReverts++;
        }
    }

    // ----------------------------------------------------------------------------------------
    // Hostile calls: nothing privileged exists, and the token refuses ether
    // ----------------------------------------------------------------------------------------

    /// @notice Every admin-shaped selector, from a stranger or from the deployer, fails and changes nothing.
    function adminAttempt(uint256 callerSeed, uint256 sigSeed, uint256 targetSeed, uint256 amount) public {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "seize(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)",
            "rescueTokens(address,uint256)"
        ];
        address caller = _actor(callerSeed);
        address target = _receiver(targetSeed);
        string memory sig = signatures[bound(sigSeed, 0, signatures.length - 1)];
        uint256 supplyBefore = token.totalSupply();
        uint256 targetBefore = token.balanceOf(target);

        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, target, amount));
        require(!ok, string.concat("privileged call succeeded: ", sig));
        require(token.totalSupply() == supplyBefore, "a privileged call changed the supply");
        require(token.balanceOf(target) == targetBefore, "a privileged call changed a balance");
        ghost_adminAttempts++;
    }

    /// @notice The token has no receive or fallback: ether sent to it bounces.
    function sendEther(uint256 fromSeed, uint256 amount) public {
        address from = _actor(fromSeed);
        amount = bound(amount, 1, 1_000 ether);
        vm.deal(from, amount);
        vm.prank(from);
        (bool ok,) = address(token).call{value: amount}("");
        require(!ok, "the token accepted ether");
        require(address(token).balance == 0, "the token holds ether");
        ghost_expectedReverts++;
    }
}

/// @notice Invariants that must hold after every random sequence the handler drives.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RobobetTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    RobobetHandler internal handler;
    RobobetToken internal token;
    bytes32 internal runtimeHash;

    function setUp() public {
        handler = new RobobetHandler();
        token = handler.token();
        runtimeHash = keccak256(address(token).code);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = RobobetHandler.transfer.selector;
        selectors[1] = RobobetHandler.transferUnbounded.selector;
        selectors[2] = RobobetHandler.transferToZero.selector;
        selectors[3] = RobobetHandler.approve.selector;
        selectors[4] = RobobetHandler.approveZeroSpender.selector;
        selectors[5] = RobobetHandler.transferFrom.selector;
        selectors[6] = RobobetHandler.transferFromUnbounded.selector;
        selectors[7] = RobobetHandler.adminAttempt.selector;
        selectors[8] = RobobetHandler.sendEther.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Fixed supply: no sequence of calls, hostile or ordinary, changes totalSupply.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "totalSupply drifted");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Conservation: what the tracked holders hold adds up to the supply, and each holds exactly
    ///      what the ghost ledger says it received minus what it sent. Nobody ends up with more than
    ///      they were given.
    function invariant_balancesMatchGhostLedgerAndSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address holder = handler.holders(i);
            uint256 balance = token.balanceOf(holder);
            assertEq(balance, handler.ghost_balance(holder), "balance disagrees with ghost ledger");
            assertEq(
                balance, handler.ghost_received(holder) - handler.ghost_sent(holder), "holder has more than it was sent"
            );
            assertLe(balance, SUPPLY, "a single holder exceeds the supply");
            sum += balance;
        }
        assertEq(sum, token.totalSupply(), "tracked balances do not sum to the supply");
    }

    /// @dev Tokens sent to the token contract are gone for good: nobody can pull them back out, so the
    ///      sink only ever grows and holds exactly what was sunk.
    function invariant_sinkOnlyGrows() public view {
        assertEq(token.balanceOf(address(token)), handler.ghost_sunk(), "sink balance moved");
    }

    /// @dev The zero address never holds anything: there is no burn and no mint, and transfers to it revert.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Allowances are exactly what was approved minus what was spent, infinite ones excepted.
    function invariant_allowancesMatchGhostLedger() public view {
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.holders(i);
                address spender = handler.holders(j);
                assertEq(token.allowance(owner, spender), handler.ghost_allowance(owner, spender), "allowance drifted");
            }
            assertEq(token.allowance(handler.holders(i), address(0)), 0, "zero spender has an allowance");
        }
    }

    /// @dev No sequence of calls changes the token's code (no SELFDESTRUCT, no proxy) or leaves ether in it.
    function invariant_codeUnchangedAndNoEther() public view {
        assertEq(keccak256(address(token).code), runtimeHash, "runtime code changed");
        assertEq(address(token).balance, 0, "token holds ether");
    }

    /// @dev Liveness: after any sequence, every actor with a balance can still move all of it. Run as a
    ///      snapshot so the check itself leaves no trace in the sequence.
    function invariant_everyHolderCanStillTransferEverything() public {
        uint256 snapshot = vm.snapshotState();
        uint256 n = handler.holderCount();
        address sink = address(0x5111);
        for (uint256 i; i < n; ++i) {
            address holder = handler.holders(i);
            if (holder == address(token)) continue;
            uint256 balance = token.balanceOf(holder);
            vm.prank(holder);
            assertTrue(token.transfer(sink, balance), "holder could not transfer");
            assertEq(token.balanceOf(holder), 0, "holder kept something back");
        }
        assertEq(token.balanceOf(sink), SUPPLY - token.balanceOf(address(token)), "liveness sweep arrived short");
        vm.revertToState(snapshot);
    }

    /// @dev Grounds the harness: each handler path, driven once with inputs chosen to reach its success
    ///      and its failure branch, advances the ghost counters it claims to. A handler that silently
    ///      took the wrong branch would make the invariants above vacuous.
    function test_handlerReachesEveryPath() public {
        // Seed 0 is the deployer, which holds the supply; seed 1 is an EOA with nothing.
        handler.transfer(0, 1, 1_000 ether);
        assertEq(handler.ghost_transfers(), 1);
        assertEq(token.balanceOf(handler.holders(1)), 1_000 ether);

        handler.transferUnbounded(1, 2, 1_000 ether + 1); // one wei above the balance: expected revert
        assertEq(handler.ghost_expectedReverts(), 1);
        handler.transferUnbounded(1, 2, 400 ether); // affordable: moves
        assertEq(handler.ghost_transfers(), 2);
        assertEq(token.balanceOf(handler.holders(2)), 400 ether);

        handler.transferToZero(1, 1);
        assertEq(handler.ghost_expectedReverts(), 2);

        handler.approve(1, 2, 100 ether);
        assertEq(token.allowance(handler.holders(1), handler.holders(2)), 100 ether);
        handler.approveZeroSpender(1, 1);
        assertEq(handler.ghost_expectedReverts(), 3);

        handler.transferFrom(2, 1, 3, 60 ether);
        assertEq(handler.ghost_transferFroms(), 1);
        assertEq(token.allowance(handler.holders(1), handler.holders(2)), 40 ether);
        handler.transferFromUnbounded(2, 1, 3, 41 ether); // above the allowance
        assertEq(handler.ghost_expectedReverts(), 4);
        handler.approve(1, 2, type(uint256).max);
        handler.transferFromUnbounded(2, 1, 3, 600 ether); // allowed, above the balance (540 ether left)
        assertEq(handler.ghost_expectedReverts(), 5);
        handler.transferFromUnbounded(2, 1, 3, 40 ether); // within both
        assertEq(handler.ghost_transferFroms(), 2);
        assertEq(token.allowance(handler.holders(1), handler.holders(2)), type(uint256).max);

        handler.transfer(1, 5, 1 ether); // seed 5 is the token contract: the sink
        assertEq(handler.ghost_sunk(), 1 ether);

        handler.adminAttempt(1, 0, 1, 1);
        handler.adminAttempt(0, 3, 1, 1);
        assertEq(handler.ghost_adminAttempts(), 2);
        handler.sendEther(1, 1 ether);
        assertEq(handler.ghost_expectedReverts(), 6);

        // After the scripted sequence every invariant still holds.
        invariant_totalSupplyNeverChanges();
        invariant_balancesMatchGhostLedgerAndSumToSupply();
        invariant_sinkOnlyGrows();
        invariant_allowancesMatchGhostLedger();
        invariant_codeUnchangedAndNoEther();
        invariant_everyHolderCanStillTransferEverything();
    }
}
