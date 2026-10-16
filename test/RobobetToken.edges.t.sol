// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Edge inputs the main suite does not pin: zero and one wei, the full supply, the maximum
///         allowance, the same call twice, callers the code did not assume, and the paths that must
///         fail. Complements `RobobetToken.t.sol`; nothing here repeats it.
/// forge-config: default.fuzz.runs = 1000
contract RobobetTokenEdgesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    RobobetToken internal token;
    address internal constant DEPLOYER = address(0xFAC7);
    address internal constant HOLDER = address(0x401D);
    address internal constant SPENDER = address(0x5BE4);
    address internal constant OTHER = address(0x07E5);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new RobobetToken();
    }

    function _fund(address to, uint256 amount) internal {
        vm.prank(DEPLOYER);
        token.transfer(to, amount);
    }

    // ----------------------------------------------------------------------------------------
    // Deployment edges
    // ----------------------------------------------------------------------------------------

    /// @dev Whoever deploys gets the supply: the mint goes to `msg.sender`, never to a fixed address.
    function testFuzz_anyDeployerReceivesTheWholeSupply(uint160 seed) public {
        address deployer = address(uint160(bound(uint256(seed), 1, type(uint160).max)));
        vm.prank(deployer);
        RobobetToken fresh = new RobobetToken();
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(DEPLOYER), 0, "the first deployer received from a second deployment");
    }

    /// @dev Two deployments are independent: the second cannot touch or inflate the first.
    function test_secondDeploymentDoesNotAffectTheFirst() public {
        vm.prank(OTHER);
        RobobetToken second = new RobobetToken();
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(OTHER), 0);
        assertEq(second.balanceOf(DEPLOYER), 0);
        assertEq(keccak256(address(second).code), keccak256(address(token).code), "runtime is not reproducible");
    }

    /// @dev The whole supply is exactly 1e27 minor units: one unit above or below is not the manifest's figure.
    function test_supplyIsExactlyOneBillionTimesTenToTheEighteen() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }

    // ----------------------------------------------------------------------------------------
    // Transfer edges: one wei, the full supply, the same call twice
    // ----------------------------------------------------------------------------------------

    function test_transferOneWei() public {
        _fund(HOLDER, 1);
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, 1));
        assertEq(token.balanceOf(HOLDER), 0);
        assertEq(token.balanceOf(OTHER), 1);
    }

    function test_transferTheWholeSupplyInOneCall() public {
        vm.prank(DEPLOYER);
        assertTrue(token.transfer(HOLDER, SUPPLY));
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(HOLDER), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The second identical transfer fails once the balance is gone: a transfer is not idempotent.
    function test_sameTransferTwiceFailsTheSecondTime() public {
        _fund(HOLDER, 10 ether);
        vm.startPrank(HOLDER);
        assertTrue(token.transfer(OTHER, 10 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 0, 10 ether));
        token.transfer(OTHER, 10 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(OTHER), 10 ether);
    }

    /// @dev A transfer of zero from an address that holds nothing succeeds and emits a zero-valued event.
    function test_zeroTransferFromEmptyAccountEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(OTHER, HOLDER, 0);
        vm.prank(OTHER);
        assertTrue(token.transfer(HOLDER, 0));
    }

    /// @dev Even one wei above the balance of the deployer, who holds everything, reverts.
    function test_deployerCannotTransferMoreThanTheSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        vm.prank(DEPLOYER);
        token.transfer(HOLDER, SUPPLY + 1);
    }

    /// @dev A self-transfer above the balance still reverts: there is no short-circuit for `to == from`.
    function test_selfTransferAboveBalanceReverts() public {
        _fund(HOLDER, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 1 ether, 2 ether)
        );
        vm.prank(HOLDER);
        token.transfer(HOLDER, 2 ether);
    }

    /// @dev Tokens sent to the token contract are stuck: it has no rescue and cannot act for itself.
    function test_tokensSentToTheContractAreStuck() public {
        _fund(address(token), 5 ether);
        assertEq(token.balanceOf(address(token)), 5 ether);
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescueTokens(address,uint256)", HOLDER, 5 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("withdraw(address,uint256)", HOLDER, 5 ether));
        assertFalse(ok);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, DEPLOYER, 0, 1));
        token.transferFrom(address(token), DEPLOYER, 1);
        assertEq(token.balanceOf(address(token)), 5 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A call whose msg.sender is the zero address is refused even for zero value.
    function test_transferFromTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(HOLDER, 0);
    }

    // ----------------------------------------------------------------------------------------
    // Allowance edges
    // ----------------------------------------------------------------------------------------

    /// @dev Approvals overwrite rather than add.
    function test_approveOverwritesInsteadOfAccumulating() public {
        vm.startPrank(HOLDER);
        token.approve(SPENDER, 100);
        token.approve(SPENDER, 40);
        vm.stopPrank();
        assertEq(token.allowance(HOLDER, SPENDER), 40);
    }

    /// @dev Approving zero clears the allowance and emits.
    function test_approveZeroClearsAllowance() public {
        vm.startPrank(HOLDER);
        token.approve(SPENDER, 100);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(HOLDER, SPENDER, 0);
        token.approve(SPENDER, 0);
        vm.stopPrank();
        assertEq(token.allowance(HOLDER, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, OTHER, 1);
    }

    /// @dev An allowance does not require a balance, and does not create one.
    function test_approveWithoutBalanceThenSpendFailsOnBalance() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, SUPPLY);
        assertEq(token.allowance(HOLDER, SPENDER), SUPPLY);
        assertEq(token.balanceOf(HOLDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, OTHER, 1);
        assertEq(token.allowance(HOLDER, SPENDER), SUPPLY, "a failed transferFrom consumed allowance");
    }

    /// @dev Spending the exact allowance leaves zero; the next wei is refused.
    function test_exactAllowanceSpentToZero() public {
        _fund(HOLDER, 10 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, 10 ether);
        vm.startPrank(SPENDER);
        assertTrue(token.transferFrom(HOLDER, OTHER, 10 ether));
        assertEq(token.allowance(HOLDER, SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        token.transferFrom(HOLDER, OTHER, 1);
        vm.stopPrank();
    }

    /// @dev Just below the infinite allowance is finite and is decremented like any other.
    function test_maxMinusOneAllowanceIsDecremented() public {
        _fund(HOLDER, 1 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, type(uint256).max - 1);
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, OTHER, 1 ether);
        assertEq(token.allowance(HOLDER, SPENDER), type(uint256).max - 1 - 1 ether);
    }

    /// @dev transferFrom emits exactly one Transfer and no Approval when it decrements the allowance.
    function test_transferFromEmitsOnlyTransfer() public {
        _fund(HOLDER, 3 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, 3 ether);
        vm.recordLogs();
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, OTHER, 2 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than one event");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), HOLDER);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), OTHER);
        assertEq(abi.decode(logs[0].data, (uint256)), 2 ether);
    }

    /// @dev An owner can approve themself and pull their own balance through transferFrom.
    function test_selfApprovalAndSelfTransferFrom() public {
        _fund(HOLDER, 2 ether);
        vm.startPrank(HOLDER);
        token.approve(HOLDER, 1 ether);
        assertTrue(token.transferFrom(HOLDER, OTHER, 1 ether));
        vm.stopPrank();
        assertEq(token.balanceOf(OTHER), 1 ether);
        assertEq(token.allowance(HOLDER, HOLDER), 0);
    }

    /// @dev A spender with allowance still cannot send the owner's tokens to the zero address.
    function test_transferFromToZeroAddressReverts() public {
        _fund(HOLDER, 1 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, address(0), 1);
    }

    /// @dev Nobody can be approved by the zero address, so nothing can ever be pulled "from" it.
    function test_transferFromTheZeroOwnerReverts() public {
        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        token.transferFrom(address(0), OTHER, 1);
    }

    /// @dev An allowance is per spender: a third party with none cannot use another's.
    function test_allowanceIsNotTransferableBetweenSpenders() public {
        _fund(HOLDER, 1 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, 0, 1));
        vm.prank(OTHER);
        token.transferFrom(HOLDER, OTHER, 1);
    }

    /// @dev The classic ERC-20 approval race is present, as the README states: a spender who front-runs
    ///      a re-approval can spend the old and the new allowance. Pinned here so a later change that
    ///      claims to remove it is caught, not asserted as a defect of this implementation.
    function test_approvalRaceIsTheStandardOne() public {
        _fund(HOLDER, 200 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, 100 ether);
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, SPENDER, 100 ether);
        vm.prank(HOLDER);
        token.approve(SPENDER, 50 ether);
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, SPENDER, 50 ether);
        assertEq(token.balanceOf(SPENDER), 150 ether);
    }

    // ----------------------------------------------------------------------------------------
    // Fuzz: allowance arithmetic at its edges
    // ----------------------------------------------------------------------------------------

    /// @dev Spending in two steps consumes exactly the sum, whatever the split.
    function testFuzz_twoPartialSpendsConsumeExactlyTheirSum(uint256 allowed, uint256 first, uint256 second) public {
        allowed = bound(allowed, 0, SUPPLY);
        first = bound(first, 0, allowed);
        second = bound(second, 0, allowed - first);
        _fund(HOLDER, allowed);
        vm.prank(HOLDER);
        token.approve(SPENDER, allowed);
        vm.startPrank(SPENDER);
        token.transferFrom(HOLDER, OTHER, first);
        token.transferFrom(HOLDER, OTHER, second);
        vm.stopPrank();
        assertEq(token.allowance(HOLDER, SPENDER), allowed - first - second);
        assertEq(token.balanceOf(OTHER), first + second);
        assertEq(token.balanceOf(HOLDER), allowed - first - second);
    }

    /// @dev Re-approving to any value replaces the old one exactly, never adds to or subtracts from it.
    function testFuzz_reapproveReplaces(uint256 a, uint256 b) public {
        vm.startPrank(HOLDER);
        token.approve(SPENDER, a);
        token.approve(SPENDER, b);
        vm.stopPrank();
        assertEq(token.allowance(HOLDER, SPENDER), b);
    }

    /// @dev A transfer is reversible: sending an amount and receiving it back restores both balances.
    function testFuzz_roundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(DEPLOYER);
        token.transfer(HOLDER, amount);
        vm.prank(HOLDER);
        token.transfer(DEPLOYER, amount);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
        assertEq(token.balanceOf(HOLDER), 0);
    }

    /// @dev Any unknown four-byte selector, with any payload, reverts and leaves the supply alone.
    function testFuzz_unknownSelectorReverts(bytes4 selector, bytes calldata payload) public {
        if (
            selector == token.transfer.selector || selector == token.approve.selector
                || selector == token.transferFrom.selector || selector == token.balanceOf.selector
                || selector == token.allowance.selector || selector == token.totalSupply.selector
                || selector == token.name.selector || selector == token.symbol.selector
                || selector == token.decimals.selector || selector == token.TOKEN_NAME.selector
                || selector == token.TOKEN_SYMBOL.selector || selector == token.DECIMALS.selector
                || selector == token.TOTAL_SUPPLY.selector
        ) {
            selector = bytes4(keccak256("notAFunction()"));
        }
        (bool ok,) = address(token).call(abi.encodePacked(selector, payload));
        assertFalse(ok, "unknown selector was accepted");
        assertEq(token.totalSupply(), SUPPLY);
    }
}
