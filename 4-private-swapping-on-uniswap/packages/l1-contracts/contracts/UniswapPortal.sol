pragma solidity >=0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IRegistry} from "@aztec/l1-contracts/src/core/interfaces/messagebridge/IRegistry.sol";
import {IOutbox} from  "@aztec/l1-contracts/src/core/interfaces/messagebridge/IOutbox.sol";
import {DataStructures} from "@aztec/l1-contracts/src/core/libraries/DataStructures.sol";
import {DataStructures as PortalDataStructures} from "./DataStructures.sol";
import {Hash} from "@aztec/l1-contracts/src/core/libraries/Hash.sol";

import {TokenPortal} from "./TokenPortal.sol";
import {ISwapRouter} from "../external/ISwapRouter.sol";

/**
 * @title UniswapPortal
 * @author Aztec Labs
 * @notice A minimal portal that allow an user inside L2, to withdraw asset A from the Rollup
 * swap asset A to asset B, and deposit asset B into the rollup again.
 * Relies on Uniswap for doing the swap, TokenPortals for A and B to get and send tokens
 * and the message boxes (inbox & outbox).
 */
contract UniswapPortal {
  ISwapRouter public constant ROUTER = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

  IRegistry public registry;
  bytes32 public l2UniswapAddress;

  function initialize(address _registry, bytes32 _l2UniswapAddress) external {
    registry = IRegistry(_registry);
    l2UniswapAddress = _l2UniswapAddress;
  }

  // Using a struct here to avoid stack too deep errors
  struct LocalSwapVars {
    IERC20 inputAsset;
    IERC20 outputAsset;
    bytes32 contentHash;
  }

  /**
 * @notice Exit with funds from L2, perform swap on L1 and deposit output asset to L2 again publicly
 * @dev `msg.value` indicates fee to submit message to inbox. Currently, anyone can call this method on your behalf.
 * They could call it with 0 fee causing the sequencer to never include in the rollup.
 * In this case, you will have to cancel the message and then make the deposit later
 * @param _inputTokenPortal - The ethereum address of the input token portal
 * @param _inAmount - The amount of assets to swap (same amount as withdrawn from L2)
 * @param _uniswapFeeTier - The fee tier for the swap on UniswapV3
 * @param _outputTokenPortal - The ethereum address of the output token portal
 * @param _amountOutMinimum - The minimum amount of output assets to receive from the swap (slippage protection)
 * @param _aztecRecipient - The aztec address to receive the output assets
 * @param _secretHashForL1ToL2Message - The hash of the secret consumable message. The hash should be 254 bits (so it can fit in a Field element)
 * @param _withCaller - When true, using `msg.sender` as the caller, otherwise address(0)
 * @return A hash of the L1 to L2 message inserted in the Inbox
 */
function swapPublic(
  address _inputTokenPortal,
  uint256 _inAmount,
  uint24 _uniswapFeeTier,
  address _outputTokenPortal,
  uint256 _amountOutMinimum,
  bytes32 _aztecRecipient,
  bytes32 _secretHashForL1ToL2Message,
  bool _withCaller,
  // Avoiding stack too deep
  PortalDataStructures.OutboxMessageMetadata[2] calldata _outboxMessageMetadata
) public returns (bytes32) {
  LocalSwapVars memory vars;

  vars.inputAsset = TokenPortal(_inputTokenPortal).underlying();
  vars.outputAsset = TokenPortal(_outputTokenPortal).underlying();

  // Withdraw the input asset from the portal
  {
    TokenPortal(_inputTokenPortal).withdraw(
      address(this),
      _inAmount,
      true,
      _outboxMessageMetadata[0]._l2BlockNumber,
      _outboxMessageMetadata[0]._leafIndex,
      _outboxMessageMetadata[0]._path
    );
  }

  {
    // prevent stack too deep errors
    vars.contentHash = Hash.sha256ToField(
      abi.encodeWithSignature(
        "swap_public(address,uint256,uint24,address,uint256,bytes32,bytes32,address)",
        _inputTokenPortal,
        _inAmount,
        _uniswapFeeTier,
        _outputTokenPortal,
        _amountOutMinimum,
        _aztecRecipient,
        _secretHashForL1ToL2Message,
        _withCaller ? msg.sender : address(0)
      )
    );
  }

  // Consume the message from the outbox
  {
    IOutbox outbox = registry.getOutbox();

    outbox.consume(
      DataStructures.L2ToL1Msg({
        sender: DataStructures.L2Actor(l2UniswapAddress, 1),
        recipient: DataStructures.L1Actor(address(this), block.chainid),
        content: vars.contentHash
      }),
      _outboxMessageMetadata[1]._l2BlockNumber,
      _outboxMessageMetadata[1]._leafIndex,
      _outboxMessageMetadata[1]._path
    );
  }

  // Perform the swap
  ISwapRouter.ExactInputSingleParams memory swapParams;
  {
    swapParams = ISwapRouter.ExactInputSingleParams({
      tokenIn: address(vars.inputAsset),
      tokenOut: address(vars.outputAsset),
      fee: _uniswapFeeTier,
      recipient: address(this),
      deadline: block.timestamp,
      amountIn: _inAmount,
      amountOutMinimum: _amountOutMinimum,
      sqrtPriceLimitX96: 0
    });
  }
  // Note, safeApprove was deprecated from Oz
  vars.inputAsset.approve(address(ROUTER), _inAmount);
  uint256 amountOut = ROUTER.exactInputSingle(swapParams);

  // approve the output token portal to take funds from this contract
  // Note, safeApprove was deprecated from Oz
  vars.outputAsset.approve(address(_outputTokenPortal), amountOut);

  // Deposit the output asset to the L2 via its portal
  return TokenPortal(_outputTokenPortal).depositToAztecPublic(
    _aztecRecipient, amountOut, _secretHashForL1ToL2Message
  );
}


  /**
   * @notice Exit with funds from L2, perform swap on L1 and deposit output asset to L2 again privately
   * @dev `msg.value` indicates fee to submit message to inbox. Currently, anyone can call this method on your behalf.
   * They could call it with 0 fee causing the sequencer to never include in the rollup.
   * In this case, you will have to cancel the message and then make the deposit later
   * @param _inputTokenPortal - The ethereum address of the input token portal
   * @param _inAmount - The amount of assets to swap (same amount as withdrawn from L2)
   * @param _uniswapFeeTier - The fee tier for the swap on UniswapV3
   * @param _outputTokenPortal - The ethereum address of the output token portal
   * @param _amountOutMinimum - The minimum amount of output assets to receive from the swap (slippage protection)
   * @param _secretHashForRedeemingMintedNotes - The hash of the secret to redeem minted notes privately on Aztec. The hash should be 254 bits (so it can fit in a Field element)
   * @param _secretHashForL1ToL2Message - The hash of the secret consumable message. The hash should be 254 bits (so it can fit in a Field element)
   * @param _withCaller - When true, using `msg.sender` as the caller, otherwise address(0)
   * @return A hash of the L1 to L2 message inserted in the Inbox
   */
  function swapPrivate(
    address _inputTokenPortal,
    uint256 _inAmount,
    uint24 _uniswapFeeTier,
    address _outputTokenPortal,
    uint256 _amountOutMinimum,
    bytes32 _secretHashForRedeemingMintedNotes,
    bytes32 _secretHashForL1ToL2Message,
    bool _withCaller,
    // Avoiding stack too deep
    PortalDataStructures.OutboxMessageMetadata[2] calldata _outboxMessageMetadata
  ) public returns (bytes32) {
    LocalSwapVars memory vars;

    vars.inputAsset = TokenPortal(_inputTokenPortal).underlying();
    vars.outputAsset = TokenPortal(_outputTokenPortal).underlying();

    {
      TokenPortal(_inputTokenPortal).withdraw(
        address(this),
        _inAmount,
        true,
        _outboxMessageMetadata[0]._l2BlockNumber,
        _outboxMessageMetadata[0]._leafIndex,
        _outboxMessageMetadata[0]._path
      );
    }

    {
      // prevent stack too deep errors
      vars.contentHash = Hash.sha256ToField(
        abi.encodeWithSignature(
          "swap_private(address,uint256,uint24,address,uint256,bytes32,bytes32,address)",
          _inputTokenPortal,
          _inAmount,
          _uniswapFeeTier,
          _outputTokenPortal,
          _amountOutMinimum,
          _secretHashForRedeemingMintedNotes,
          _secretHashForL1ToL2Message,
          _withCaller ? msg.sender : address(0)
        )
      );
    }

    // Consume the message from the outbox
    {
      IOutbox outbox = registry.getOutbox();

      outbox.consume(
        DataStructures.L2ToL1Msg({
          sender: DataStructures.L2Actor(l2UniswapAddress, 1),
          recipient: DataStructures.L1Actor(address(this), block.chainid),
          content: vars.contentHash
        }),
        _outboxMessageMetadata[1]._l2BlockNumber,
        _outboxMessageMetadata[1]._leafIndex,
        _outboxMessageMetadata[1]._path
      );
    }

    // Perform the swap
    ISwapRouter.ExactInputSingleParams memory swapParams;
    {
      swapParams = ISwapRouter.ExactInputSingleParams({
        tokenIn: address(vars.inputAsset),
        tokenOut: address(vars.outputAsset),
        fee: _uniswapFeeTier,
        recipient: address(this),
        deadline: block.timestamp,
        amountIn: _inAmount,
        amountOutMinimum: _amountOutMinimum,
        sqrtPriceLimitX96: 0
      });
    }
    // Note, safeApprove was deprecated from Oz
    vars.inputAsset.approve(address(ROUTER), _inAmount);
    uint256 amountOut = ROUTER.exactInputSingle(swapParams);

    // approve the output token portal to take funds from this contract
    // Note, safeApprove was deprecated from Oz
    vars.outputAsset.approve(address(_outputTokenPortal), amountOut);

    // Deposit the output asset to the L2 via its portal
    return TokenPortal(_outputTokenPortal).depositToAztecPrivate(
      _secretHashForRedeemingMintedNotes, amountOut, _secretHashForL1ToL2Message
    );
  }
   function withdraw(
    address _recipient,
    uint256 _amount,
    bool _withCaller,
    uint256 _l2BlockNumber,
    uint256 _leafIndex,
    bytes32[] calldata _path
  ) external {
    DataStructures.L2ToL1Msg memory message = DataStructures.L2ToL1Msg({
      sender: DataStructures.L2Actor(l2Bridge, 1),
      recipient: DataStructures.L1Actor(address(this), block.chainid),
      content: Hash.sha256ToField(
        abi.encodeWithSignature(
          "withdraw(address,uint256,address)",
          _recipient,
          _amount,
          _withCaller ? msg.sender : address(0)
        )
        )
    });

    IOutbox outbox = registry.getOutbox();

    outbox.consume(message, _l2BlockNumber, _leafIndex, _path);

    underlying.transfer(_recipient, _amount);
  }
}