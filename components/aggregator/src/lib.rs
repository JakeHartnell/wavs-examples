#[allow(warnings)]
#[rustfmt::skip]
mod bindings;

use crate::bindings::{
    export, host,
    wavs::{
        aggregator::{
            input::AggregatorInput,
            output::{AggregatorAction, EvmAddress, EvmSubmitAction, SubmitAction},
        },
        types::{chain::AnyTxHash},
    },
    Guest,
};

struct Component;

impl Guest for Component {
    fn process_input(input: AggregatorInput) -> Result<Vec<AggregatorAction>, String> {
        let workflow = host::get_workflow().workflow;

        let submit_config = match workflow.submit {
            bindings::wavs::types::service::Submit::None => {
                return Err("submit is none".to_string());
            }
            bindings::wavs::types::service::Submit::Aggregator(s) => s.component.config,
        };

        let mut actions = Vec::new();

        for (chain_key, service_handler_address) in submit_config {
            if host::get_evm_chain_config(&chain_key).is_some() {
                let address: alloy_primitives::Address = service_handler_address
                    .parse()
                    .map_err(|e| format!("Failed to parse address for '{chain_key}': {e}"))?;

                actions.push(AggregatorAction::Submit(SubmitAction::Evm(EvmSubmitAction {
                    chain: chain_key,
                    address: EvmAddress { raw_bytes: address.to_vec() },
                    gas_price: None,
                })));
            }
        }

        Ok(actions)
    }

    fn handle_timer_callback(_input: AggregatorInput) -> Result<Vec<AggregatorAction>, String> {
        Ok(vec![])
    }

    fn handle_submit_callback(
        _input: AggregatorInput,
        _tx_result: Result<AnyTxHash, String>,
    ) -> Result<(), String> {
        Ok(())
    }
}

export!(Component with_types_in bindings);
