// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Stands in for the launch factory: deploys the token from its creation code through CREATE2
///         so the test can check that `msg.sender` of the constructor, not the test, receives the supply.
contract FactoryStub {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(RobobetToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract RobobetTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant SWARM_BPS = 1_000;
    uint256 internal constant POOL_BPS = 8_800;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed deployer, uint256 supply);

    FactoryStub internal factory;
    RobobetToken internal token;

    address internal constant DISTRIBUTOR = address(0xD157);
    address internal constant CLAIMANT = address(0xC1A1);
    address internal constant HOLDER = address(0x401D);
    address internal constant OTHER = address(0x07E5);
    address internal constant ATTACKER = address(0xBEEF);

    function setUp() public {
        factory = new FactoryStub();
        token = RobobetToken(factory.deploy(type(RobobetToken).creationCode, bytes32(uint256(1))));
    }

    // ----------------------------------------------------------------------------------------
    // Metadata and supply
    // ----------------------------------------------------------------------------------------

    function test_nameSymbolDecimals() public view {
        assertEq(token.name(), "Robobet");
        assertEq(token.symbol(), "ROBOBET");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Robobet");
        assertEq(token.TOKEN_SYMBOL(), "ROBOBET");
        assertEq(token.DECIMALS(), 18);
    }

    function test_totalSupplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
    }

    function test_wholeSupplyMintedToDeployerOnce() public view {
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test harness must not receive anything");
    }

    function test_constructorEmitsMintTransferAndSupplyMinted() public {
        address deployer = address(0xFAC7);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.expectEmit(true, true, true, true, predicted);
        emit Transfer(address(0), deployer, EXPECTED_SUPPLY);
        vm.expectEmit(true, true, true, true, predicted);
        emit SupplyMinted(deployer, EXPECTED_SUPPLY);
        vm.prank(deployer);
        RobobetToken fresh = new RobobetToken();
        assertEq(address(fresh), predicted);
        assertEq(fresh.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_constructorTakesNoArgumentsAndCallsNoContract() public {
        // Deploying from a fresh EOA on an otherwise empty chain succeeds: nothing external is read.
        address lone = address(0x10E);
        vm.prank(lone);
        RobobetToken fresh = new RobobetToken();
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(lone), EXPECTED_SUPPLY);
    }

    // ----------------------------------------------------------------------------------------
    // Launch flows: the swarm share, the pool share and the remainder all arrive whole
    // ----------------------------------------------------------------------------------------

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0, "distributor kept something back");
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "launch flows changed the supply");
    }

    function test_launchSplitConservesSupply() public {
        address remainderTo = address(0x0120a4CcC7516344DbFEDc9d43fF7859B7CCCa97);
        address pool = address(0x9001);
        uint256 swarm = (EXPECTED_SUPPLY * SWARM_BPS) / 10_000;
        uint256 poolShare = (EXPECTED_SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - poolShare;

        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertTrue(factory.move(token, pool, poolShare));
        assertTrue(factory.move(token, remainderTo, remainder));

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(pool), poolShare);
        assertEq(token.balanceOf(remainderTo), remainder);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(swarm + poolShare + remainder, EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ----------------------------------------------------------------------------------------
    // Ordinary ERC-20 success paths
    // ----------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        factory.move(token, HOLDER, 1_000 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(HOLDER, OTHER, 400 ether);
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, 400 ether));
        assertEq(token.balanceOf(HOLDER), 600 ether);
        assertEq(token.balanceOf(OTHER), 400 ether);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, 0));
        assertEq(token.balanceOf(OTHER), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        factory.move(token, HOLDER, 5 ether);
        vm.prank(HOLDER);
        assertTrue(token.transfer(HOLDER, 5 ether));
        assertEq(token.balanceOf(HOLDER), 5 ether);
    }

    function test_approveAndTransferFrom() public {
        factory.move(token, HOLDER, 1_000 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(HOLDER, OTHER, 300 ether);
        vm.prank(HOLDER);
        assertTrue(token.approve(OTHER, 300 ether));
        assertEq(token.allowance(HOLDER, OTHER), 300 ether);

        vm.prank(OTHER);
        assertTrue(token.transferFrom(HOLDER, CLAIMANT, 200 ether));
        assertEq(token.balanceOf(HOLDER), 800 ether);
        assertEq(token.balanceOf(CLAIMANT), 200 ether);
        assertEq(token.allowance(HOLDER, OTHER), 100 ether, "allowance not decremented");
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.move(token, HOLDER, 10 ether);
        vm.prank(HOLDER);
        token.approve(OTHER, type(uint256).max);
        vm.prank(OTHER);
        token.transferFrom(HOLDER, CLAIMANT, 10 ether);
        assertEq(token.allowance(HOLDER, OTHER), type(uint256).max);
    }

    // ----------------------------------------------------------------------------------------
    // Failure paths
    // ----------------------------------------------------------------------------------------

    function test_revert_transferMoreThanBalance() public {
        factory.move(token, HOLDER, 10 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 10 ether, 10 ether + 1)
        );
        vm.prank(HOLDER);
        token.transfer(OTHER, 10 ether + 1);
    }

    function test_revert_transferFromWithoutAllowance() public {
        factory.move(token, HOLDER, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, 0, 1 ether));
        vm.prank(OTHER);
        token.transferFrom(HOLDER, OTHER, 1 ether);
    }

    function test_revert_transferFromBeyondAllowance() public {
        factory.move(token, HOLDER, 10 ether);
        vm.prank(HOLDER);
        token.approve(OTHER, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, 1 ether, 2 ether)
        );
        vm.prank(OTHER);
        token.transferFrom(HOLDER, OTHER, 2 ether);
    }

    function test_revert_transferFromBeyondBalanceEvenWithAllowance() public {
        factory.move(token, HOLDER, 1 ether);
        vm.prank(HOLDER);
        token.approve(OTHER, 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, 1 ether, 2 ether)
        );
        vm.prank(OTHER);
        token.transferFrom(HOLDER, OTHER, 2 ether);
    }

    function test_revert_transferToZeroAddress() public {
        factory.move(token, HOLDER, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(HOLDER);
        token.transfer(address(0), 1);
    }

    function test_revert_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(HOLDER);
        token.approve(address(0), 1);
    }

    // ----------------------------------------------------------------------------------------
    // No admin: supply cannot grow, nobody can move or freeze a holder's balance
    // ----------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupply() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(ATTACKER), 0, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        factory.move(token, HOLDER, EXPECTED_SUPPLY / 1_000);
        uint256 held = token.balanceOf(HOLDER);
        assertGt(held, 0);
        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], HOLDER, true);
            vm.prank(address(factory));
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        vm.prank(address(factory));
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, HOLDER, address(factory), 1));
        assertFalse(moved, "the deployer pulled from a holder without allowance");
        assertEq(token.balanceOf(HOLDER), held, "a privileged call moved the holder's balance");
        vm.prank(HOLDER);
        assertTrue(token.transfer(OTHER, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(OTHER), held / 2);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_unknownSelectorRevertsAndEtherIsRefused() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "unknown selector did not revert");
        vm.deal(address(this), 1 ether);
        (ok,) = address(token).call{value: 1 wei}("");
        assertFalse(ok, "token accepted ether");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "runtime code contains DELEGATECALL");
            assertTrue(op != 0xF2, "runtime code contains CALLCODE");
            assertTrue(op != 0xFF, "runtime code contains SELFDESTRUCT");
        }
    }

    // ----------------------------------------------------------------------------------------
    // Fuzz: transfers conserve supply and are exact
    // ----------------------------------------------------------------------------------------

    function testFuzz_transferIsExactAndConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(factory));
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        assertTrue(factory.move(token, to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(factory)), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferFromIsExactAndRespectsAllowance(uint256 funded, uint256 allowed, uint256 spent) public {
        funded = bound(funded, 0, EXPECTED_SUPPLY);
        allowed = bound(allowed, 0, type(uint256).max - 1);
        spent = bound(spent, 0, EXPECTED_SUPPLY);
        factory.move(token, HOLDER, funded);
        vm.prank(HOLDER);
        token.approve(OTHER, allowed);

        vm.prank(OTHER);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, OTHER, allowed, spent)
            );
            token.transferFrom(HOLDER, CLAIMANT, spent);
            return;
        }
        if (spent > funded) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, funded, spent)
            );
            token.transferFrom(HOLDER, CLAIMANT, spent);
            return;
        }
        assertTrue(token.transferFrom(HOLDER, CLAIMANT, spent));
        assertEq(token.balanceOf(CLAIMANT), spent);
        assertEq(token.balanceOf(HOLDER), funded - spent);
        assertEq(token.allowance(HOLDER, OTHER), allowed - spent);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 funded, uint256 excess) public {
        funded = bound(funded, 0, EXPECTED_SUPPLY - 1);
        excess = bound(excess, 1, EXPECTED_SUPPLY - funded);
        factory.move(token, HOLDER, funded);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, funded, funded + excess)
        );
        vm.prank(HOLDER);
        token.transfer(OTHER, funded + excess);
    }
}
