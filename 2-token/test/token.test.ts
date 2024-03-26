import { createAccount } from '@aztec/accounts/testing';
import {
  AccountWallet,
  CheatCodes,
  ExtendedNote,
  Fr,
  Note,
  PXE,
  computeMessageSecretHash,
  createPXEClient,
  waitForPXE,
} from '@aztec/aztec.js';
import { TokenContract } from './Token';

const { PXE_URL = 'http://localhost:8080', ETHEREUM_HOST = 'http://localhost:8545' } = process.env;

describe('Testing', () => {
  describe('on local sandbox', () => {
    beforeAll(async () => {
      const pxe = createPXEClient(PXE_URL);
      await waitForPXE(pxe);
    });

    describe('token contract deployed to PXE', () => {
      let pxe: PXE;
      let owner: AccountWallet;
      let recipient: AccountWallet;
      let token: TokenContract;

      beforeEach(async () => {
        pxe = createPXEClient(PXE_URL);
        owner = await createAccount(pxe);
        recipient = await createAccount(pxe);
        token = await TokenContract.deploy(owner, owner.getCompleteAddress(), 'TokenName', 'TokenSymbol', 18)
          .send()
          .deployed();
      }, 60_000);

      it('increases recipient funds on mint', async () => {
        const recipientAddress = recipient.getAddress();
        expect(await token.methods.balance_of_private(recipientAddress).view()).toEqual(0n);

        const mintAmount = 20n;
        const secret = Fr.random();
        const secretHash = computeMessageSecretHash(secret);
        await token.methods.mint_private(mintAmount, secretHash).send().wait();

        expect(await token.methods.balance_of_private(recipientAddress).view()).toEqual(20n);
      }, 30_000);
    });

    describe('cheats', () => {
      let pxe: PXE;
      let owner: AccountWallet;
      let cheats: CheatCodes;

      beforeAll(async () => {
        pxe = createPXEClient(PXE_URL);
        owner = await createAccount(pxe);
        cheats = CheatCodes.create(ETHEREUM_HOST, pxe);
      }, 30_000);

      it('warps time to 1h into the future', async () => {
        const newTimestamp = Math.floor(Date.now() / 1000) + 60 * 60 * 24;
        await cheats.aztec.warp(newTimestamp);
      });
    });
  });
});