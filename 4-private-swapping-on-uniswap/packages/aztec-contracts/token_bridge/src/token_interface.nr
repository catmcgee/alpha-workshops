use dep::aztec::prelude::{FunctionSelector, AztecAddress, EthAddress, PrivateContext};
use dep::aztec::context::{PublicContext, Context, gas::GasOpts};

struct Token {
  address: AztecAddress,
}

impl Token {
    pub fn at(address: AztecAddress) -> Self {
        Self { address }
    }

    pub fn mint_public(self: Self, context: &mut PublicContext, to: AztecAddress, amount: Field) {
        let _return_values = context.call_public_function(
            self.address,
            FunctionSelector::from_signature("mint_public((Field),Field)"),
            [to.to_field(), amount],
            GasOpts::default()
        );
    }

    pub fn burn_public(
        self: Self,
        context: &mut PublicContext,
        from: AztecAddress,
        amount: Field,
        nonce: Field
    ) {
        let _return_values = context.call_public_function(
            self.address,
            FunctionSelector::from_signature("burn_public((Field),Field,Field)"),
            [from.to_field(), amount, nonce],
            GasOpts::default()
        );
    }

    pub fn mint_private(self: Self, context: &mut PublicContext, amount: Field, secret_hash: Field) {
        let _return_values = context.call_public_function(
            self.address,
            FunctionSelector::from_signature("mint_private(Field,Field)"),
            [amount, secret_hash],
            GasOpts::default()
        );
    }

    pub fn burn(self: Self, context: &mut PrivateContext, from: AztecAddress, amount: Field, nonce: Field) {
        let _return_values = context.call_private_function(
            self.address,
            FunctionSelector::from_signature("burn((Field),Field,Field)"),
            [from.to_field(), amount, nonce]
        );
    }
}
