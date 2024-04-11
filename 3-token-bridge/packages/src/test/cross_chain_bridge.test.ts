import { expect, jest, describe, beforeEach, it } from '@jest/globals'
import { AccountWallet, AztecAddress, DebugLogger, EthAddress, Fr, computeAuthWitMessageHash, createDebugLogger, createPXEClient, waitForPXE } from '@aztec/aztec.js';
import { getInitialTestAccountsWallets } from '@aztec/accounts/testing';
import { TokenContract } from '@aztec/noir-contracts.js/Token';
import { TokenBridgeContract } from './fixtures/TokenBridge.js';
import { createAztecNodeClient } from '@aztec/circuit-types';

import { CrossChainTestHarness } from './shared/cross_chain_test_harness.js';
import { mnemonicToAccount } from 'viem/accounts';
import { createPublicClient, createWalletClient, http } from 'viem';
import { foundry } from 'viem/chains';

const { PXE_URL = 'http://localhost:8080', ETHEREUM_HOST = 'http://localhost:8545' } = process.env;
const MNEMONIC = 'test test test test test test test test test test test junk';
const hdAccount = mnemonicToAccount(MNEMONIC);
const aztecNode = createAztecNodeClient(PXE_URL);

describe('e2e_cross_chain_messaging', () => {
  jest.setTimeout(90_000);

  let logger: DebugLogger;
  let user1Wallet: AccountWallet;
  let user2Wallet: AccountWallet;
  let ethAccount: EthAddress;
  let ownerAddress: AztecAddress;

  let crossChainTestHarness: CrossChainTestHarness;
  let l2Token: TokenContract;
  let l2Bridge: TokenBridgeContract;
  let outbox: any;

  beforeEach(async () => {
    logger = createDebugLogger('aztec:e2e_uniswap');
    const pxe = createPXEClient(PXE_URL);
    await waitForPXE(pxe);
    const wallets = await getInitialTestAccountsWallets(pxe);

    const walletClient = createWalletClient({
      account: hdAccount,
      chain: foundry,
      transport: http(ETHEREUM_HOST),
    });
    const publicClient = createPublicClient({
      chain: foundry,
      transport: http(ETHEREUM_HOST),
    });

    crossChainTestHarness = await CrossChainTestHarness.new(
      aztecNode,
      pxe,
      publicClient,
      walletClient,
      wallets[0],
      logger,
    );

    l2Token = crossChainTestHarness.l2Token;
    l2Bridge = crossChainTestHarness.l2Bridge;
    ethAccount = crossChainTestHarness.ethAccount;
    ownerAddress = crossChainTestHarness.ownerAddress;
    outbox = crossChainTestHarness.outbox;
    user1Wallet = wallets[0];
    user2Wallet = wallets[1];
    logger = logger;
    logger('Successfully deployed contracts and initialized portal');
  });

  it('Privately deposit funds from L1 -> L2 and withdraw back to L1', async () => {
    // Generate a claim secret using pedersen
    const l1TokenBalance = 1000000n;
    const bridgeAmount = 100n;
  
    const [secretForL2MessageConsumption, secretHashForL2MessageConsumption] =
      crossChainTestHarness.generateClaimSecret();
    const [secretForRedeemingMintedNotes, secretHashForRedeemingMintedNotes] =
      crossChainTestHarness.generateClaimSecret();
  
    // 1. Mint tokens on L1
    await crossChainTestHarness.mintTokensOnL1(l1TokenBalance);
  
    // 2. Deposit tokens to the TokenPortal
    const msgHash = await crossChainTestHarness.sendTokensToPortalPrivate(
      secretHashForRedeemingMintedNotes,
      bridgeAmount,
      secretHashForL2MessageConsumption,
    );
    expect(await crossChainTestHarness.getL1BalanceOf(ethAccount)).toBe(l1TokenBalance - bridgeAmount);
  
    await crossChainTestHarness.makeMessageConsumable(msgHash);
  
    // 3. Consume L1 -> L2 message and mint private tokens on L2
    await crossChainTestHarness.consumeMessageOnAztecAndMintPrivately(
      secretHashForRedeemingMintedNotes,
      bridgeAmount,
      secretForL2MessageConsumption,
    );
    // tokens were minted privately in a TransparentNote which the owner (person who knows the secret) must redeem:
    await crossChainTestHarness.redeemShieldPrivatelyOnL2(bridgeAmount, secretForRedeemingMintedNotes);
    await crossChainTestHarness.expectPrivateBalanceOnL2(ownerAddress, bridgeAmount);
  
    // time to withdraw the funds again!
    logger('Withdrawing funds from L2');
  
    // 4. Give approval to bridge to burn owner's funds:
    const withdrawAmount = 9n;
    const nonce = Fr.random();
    await user1Wallet.createAuthWit({
      caller: l2Bridge.address,
      action: l2Token.methods.burn(ownerAddress, withdrawAmount, nonce),
    });
  
    // 5. Withdraw owner's funds from L2 to L1
    const l2ToL1Message = crossChainTestHarness.getL2ToL1MessageLeaf(withdrawAmount);
    const l2TxReceipt = await crossChainTestHarness.withdrawPrivateFromAztecToL1(withdrawAmount, nonce);
    await crossChainTestHarness.expectPrivateBalanceOnL2(ownerAddress, bridgeAmount - withdrawAmount);

    const [l2ToL1MessageIndex, siblingPath] = await aztecNode.getL2ToL1MessageMembershipWitness(
      l2TxReceipt.blockNumber!,
      l2ToL1Message,
    );
    // Check balance before and after exit.
    expect(await crossChainTestHarness.getL1BalanceOf(ethAccount)).toBe(l1TokenBalance - bridgeAmount);
    await crossChainTestHarness.withdrawFundsFromBridgeOnL1(
      withdrawAmount,
      l2TxReceipt.blockNumber!,
      l2ToL1MessageIndex,
      siblingPath,
    );
    expect(await crossChainTestHarness.getL1BalanceOf(ethAccount)).toBe(l1TokenBalance - bridgeAmount + withdrawAmount);
  }, 120_000);
});