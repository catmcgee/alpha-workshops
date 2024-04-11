mod token_interface;

// Minimal implementation of the token bridge that can move funds between L1 <> L2.
// The bridge has a corresponding Portal contract on L1 that it is attached to
// And corresponds to a Token on L2 that uses the `AuthWit` accounts pattern.
// Bridge has to be set as a minter on the token before it can be used

contract TokenBridge {
    use dep::aztec::prelude::{FunctionSelector, AztecAddress, EthAddress, PublicMutable};

    use dep::aztec::{context::Context, hash::compute_secret_hash};

    use dep::token_portal_content_hash_lib::{get_mint_public_content_hash, get_mint_private_content_hash, get_withdraw_content_hash};

    use crate::token_interface::Token;
 
    // Storage structure, containing all storage, and specifying what slots they use.
    #[aztec(storage)]
    struct Storage {
        token: PublicMutable<AztecAddress>,
    }

    // Constructs the contract.
    #[aztec(private)]
    #[aztec(initializer)]
    fn constructor(token: AztecAddress) {
        let selector = FunctionSelector::from_signature("_initialize((Field))");
        context.call_public_function(context.this_address(), selector, [token.to_field()]);
    }
  
    // Consumes a L1->L2 message and calls the token contract to mint the appropriate amount publicly
    #[aztec(public)]
    fn claim_public(to: AztecAddress, amount: Field, secret: Field) {
        let content_hash = get_mint_public_content_hash(to, amount);

        // Consume message and emit nullifier
        context.consume_l1_to_l2_message(content_hash, secret, context.this_portal_address());

        // Mint tokens
        Token::at(storage.token.read()).mint_public(&mut context, to, amount);
    }

    // Burns the appropriate amount of tokens and creates a L2 to L1 withdraw message publicly
    // Requires `msg.sender` to give approval to the bridge to burn tokens on their behalf using witness signatures
    #[aztec(public)]
    fn exit_to_l1_public(
        recipient: EthAddress, // ethereum address to withdraw to
        amount: Field,
        caller_on_l1: EthAddress, // ethereum address that can call this function on the L1 portal (0x0 if anyone can call)
        nonce: Field // nonce used in the approval message by `msg.sender` to let bridge burn their tokens on L2
    ) {
        // Send an L2 to L1 message
        let content = get_withdraw_content_hash(recipient, amount, caller_on_l1);
        context.message_portal(context.this_portal_address(), content);

        // Burn tokens
        Token::at(storage.token.read()).burn_public(&mut context, context.msg_sender(), amount, nonce);
    }
   
    // Consumes a L1->L2 message and calls the token contract to mint the appropriate amount in private assets
    // User needs to call token.redeem_shield() to get the private assets
    #[aztec(private)]
    fn claim_private(
        secret_hash_for_redeeming_minted_notes: Field, // secret hash used to redeem minted notes at a later time. This enables anyone to call this function and mint tokens to a user on their behalf
        amount: Field,
        secret_for_L1_to_L2_message_consumption: Field // secret used to consume the L1 to L2 message
    ) {
       // TODO
    }
  
    // Burns the appropriate amount of tokens and creates a L2 to L1 withdraw message privately
    // Requires `msg.sender` (caller of the method) to give approval to the bridge to burn tokens on their behalf using witness signatures
    #[aztec(private)]
    fn exit_to_l1_private(
        token: AztecAddress,
        recipient: EthAddress, // ethereum address to withdraw to
        amount: Field,
        caller_on_l1: EthAddress, // ethereum address that can call this function on the L1 portal (0x0 if anyone can call)
        nonce: Field // nonce used in the approval message by `msg.sender` to let bridge burn their tokens on L2
    ) {
        // TODO
    }

    // View function that is callable by other contracts.
    // Unconstrained can't be called by others since it isn't safe.
    #[aztec(public)]
    fn get_token() -> AztecAddress {
        storage.token.read()
    }

    // /// Unconstrained ///

    unconstrained fn token() -> pub AztecAddress {
        storage.token.read()
    }

    #[aztec(public)]
    #[aztec(internal)]
    #[aztec(noinitcheck)]
    fn _initialize(token: AztecAddress) {
        storage.token.write(token);
    }

    // This is a public call as we need to read from public storage.
    // Also, note that user hashes their secret in private and only sends the hash in public
    // meaning only user can `redeem_shield` at a later time with their secret.
    #[aztec(public)]
    #[aztec(internal)]
    fn _call_mint_on_token(amount: Field, secret_hash: Field) {
        Token::at(storage.token.read()).mint_private(&mut context, amount, secret_hash);
    }
  
    #[aztec(public)]
    #[aztec(internal)]
    fn _assert_token_is_same(token: AztecAddress) {
        assert(storage.token.read().eq(token), "Token address is not the same as seen in storage");
    }
}