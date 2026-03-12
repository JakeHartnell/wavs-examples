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
        types::{chain::AnyTxHash, core::LogLevel},
    },
    Guest,
};

struct Component;

impl Guest for Component {
    fn process_input(input: AggregatorInput) -> Result<Vec<AggregatorAction>, String> {
        let workflow = host::get_workflow().workflow;

        host::log(LogLevel::Info, &format!(
            "aggregator: processing input, payload={} bytes",
            input.operator_response.payload.len()
        ));

        let submit_config = match workflow.submit {
            bindings::wavs::types::service::Submit::None => {
                host::log(LogLevel::Error, "aggregator: submit config is None — nothing to do");
                return Err("submit is none".to_string());
            }
            bindings::wavs::types::service::Submit::Aggregator(s) => s.component.config,
        };

        let mut actions = Vec::new();

        for (chain_key, service_handler_address) in &submit_config {
            if host::get_evm_chain_config(chain_key).is_some() {
                let address: alloy_primitives::Address = service_handler_address
                    .parse()
                    .map_err(|e| format!("Failed to parse address for '{chain_key}': {e}"))?;

                host::log(LogLevel::Info, &format!(
                    "aggregator: submitting to chain={} address={}",
                    chain_key, service_handler_address
                ));

                actions.push(AggregatorAction::Submit(SubmitAction::Evm(EvmSubmitAction {
                    chain: chain_key.clone(),
                    address: EvmAddress { raw_bytes: address.to_vec() },
                    gas_price: None,
                })));
            } else {
                host::log(LogLevel::Warn, &format!(
                    "aggregator: no EVM chain config for '{}' — skipping",
                    chain_key
                ));
            }
        }

        host::log(LogLevel::Info, &format!(
            "aggregator: returning {} submit action(s)",
            actions.len()
        ));

        Ok(actions)
    }

    fn handle_timer_callback(_input: AggregatorInput) -> Result<Vec<AggregatorAction>, String> {
        Ok(vec![])
    }

    fn handle_submit_callback(
        _input: AggregatorInput,
        tx_result: Result<AnyTxHash, String>,
    ) -> Result<(), String> {
        match &tx_result {
            Ok(hash) => host::log(LogLevel::Info, &format!(
                "aggregator: submit confirmed, tx_hash={:?}", hash
            )),
            Err(e) => host::log(LogLevel::Error, &format!(
                "aggregator: submit failed: {}", e
            )),
        }
        Ok(())
    }
}

export!(Component with_types_in bindings);
