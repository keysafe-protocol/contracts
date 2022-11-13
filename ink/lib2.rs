#![cfg_attr(not(feature = "std"), no_std)]

use ink_lang as ink;

#[ink::contract]
mod Keysafe {

    use ink_storage::{
        traits::SpreadAllocate,
        traits::SpreadLayout,
        traits::PackedLayout,
        Mapping,
    };

    use ink_prelude::{
        string::{
            String,
            ToString,
        },
    };


    // Node is a machine running KeySafe secret storage
    #[derive(Default, PartialEq, Eq, Debug, Clone, scale::Decode, scale::Encode, SpreadAllocate, SpreadLayout, PackedLayout)]
    #[cfg_attr(feature = "std", derive(scale_info::TypeInfo))]
    struct Node {
        nid: AccountId,
        pubk: String
    }

    // User is someone who uses KeySafe to store secret
    #[derive(Default, PartialEq, Eq, Debug, Clone, scale::Decode, scale::Encode, SpreadAllocate, SpreadLayout, PackedLayout)]
    #[cfg_attr(feature = "std", derive(scale_info::TypeInfo))]
    struct User {
        uid: AccountId,
        pubk: String,
        node1_cond_type: u8,
        node1_id: AccountId,
        node2_cond_type: u8,
        node2_id: AccountId,
        node3_cond_type: u8,
        node3_id: AccountId,
    }

    // A full recovery includes at least 2 nodes each provides a user 
    // its secret share
    #[derive(Default, PartialEq, Eq, Debug, Clone, scale::Decode, scale::Encode, SpreadAllocate, SpreadLayout, PackedLayout)]
    #[cfg_attr(feature = "std", derive(scale_info::TypeInfo))]
    struct Recovery {
        status: u8, // 0 for not started, 1 for started, 2 for finished
        uid: AccountId,
        r_times: u32,
        recovery1_proof: String,
        node1_confirm: u32,
        recovery2_proof: String,
        node2_confirm: u32,
        recovery3_proof: String,
        node3_confirm: u32,
    }
  
    #[ink(storage)]
    #[derive(SpreadAllocate)]
    pub struct KeyLedger {
        /// Stores balance for both user and node
        total_supply: Balance,
        balances: ink_storage::Mapping<AccountId, Balance>,
        nodes: ink_storage::Mapping<AccountId ,Node>,
        users: ink_storage::Mapping<AccountId, User>,
        recoveries: ink_storage::Mapping<AccountId, Recovery>
    }

    pub type Result<T> = core::result::Result<T, Error>;

    /// The ERC-20 error types.
    #[derive(Debug, PartialEq, Eq, scale::Encode, scale::Decode)]
    #[cfg_attr(feature = "std", derive(scale_info::TypeInfo))]
    pub enum Error {
        /// Returned if not enough balance to fulfill a request is available.
        InsufficientBalance,
    }

    impl KeyLedger {
        /// Constructor that initializes maps
        #[ink(constructor)]
        pub fn new(total_supply: Balance) -> Self {
            ink_lang::utils::initialize_contract(|contract| {
                Self::new_init(contract, total_supply)
            })
        }

        fn new_init(&mut self, initial_supply: Balance) {
            let caller = Self::env().caller();
            self.balances.insert(&caller, &initial_supply);
            self.total_supply = initial_supply;
        }

        #[ink(message)]
        pub fn total_supply(&self) -> Balance {
            self.total_supply
        }

        #[ink(message)]
        pub fn balance_of(&self, owner: AccountId) -> Balance {
            self.balances.get(&owner).unwrap_or_default()
        }

        #[ink(message)]
        pub fn transfer(&mut self, to: AccountId, value: Balance) -> Result<()> {
            let from = self.env().caller();
            let from_balance = self.balance_of(from);
            // if from_balance < value {
            //     return Err(Error::InsufficientBalance)
            // }

            self.balances.insert(&from, &(from_balance - value));
            let to_balance = self.balance_of(to);
            self.balances.insert(to, &(to_balance + value));
            Ok(())
        }

        fn transfer_from_to(&mut self, from: &AccountId,
            to: &AccountId, value: Balance,
        ) -> Result<()> {
            let from_balance = self.balance_of(*from);
            if from_balance < value {
                return Err(Error::InsufficientBalance)
            }

            self.balances.insert(from, &(from_balance - value));
            let to_balance = self.balance_of(*to);
            self.balances.insert(to, &(to_balance + value));
            Ok(())
        }

        // for new machines just install node app, call register_node to alert the chain
        #[ink(message)]
        pub fn register_node(&mut self, pubk: String) {
            let sender = self.env().caller();
            let node = self.nodes.get(sender);
            match node {
                Some(n) => {},
                None => {
                    self.nodes.insert(sender, &Node {
                        nid: sender,
                        pubk: pubk
                    })
                }
            }
        }

        // // get all nodes registered
        // #[ink(message)]
        // pub fn get_nodes(&self) -> Vec<AccountId> {
        //     let mut result: Vec<AccountId> = Vec::new();
        //     for (k, v) in self.nodes.into_iter() {
        //         result.push(k);
        //     }
        //     result
        // }

        // for new user, call register user after all user secret shares are 
        // stored in 3 nodes
        #[ink(message)]
        pub fn register_user(&mut self, pubk: String,
            node1_cond_type: u8, node1_id: AccountId,
            node2_cond_type: u8, node2_id: AccountId,
            node3_cond_type: u8, node3_id: AccountId) {
            let sender = self.env().caller();
            let user = User {
                uid: sender,
                pubk: pubk,
                node1_cond_type: node1_cond_type,
                node1_id: node1_id,
                node2_cond_type: node2_cond_type,
                node2_id: node2_id,
                node3_cond_type: node3_cond_type,
                node3_id: node3_id
            };
            self.users.insert(sender, &user);
            let recovery = Recovery {
                status: 0,
                uid: sender,
                r_times: 0,
                recovery1_proof: "".to_string(),
                node1_confirm: 0,
                recovery2_proof: "".to_string(),
                node2_confirm: 0,
                recovery3_proof: "".to_string(),
                node3_confirm: 0
            };
            self.recoveries.insert(sender, &recovery);
        }

        // before user try to access its secret, call request_recovery 
        #[ink(message)]
        pub fn start_recovery(&mut self) {
            let sender = self.env().caller();
            let balance = self.balance_of(sender);
            // not enough balance to start a recover
            if balance < 3 {
                return
            }
            let recovery_info = self.recoveries.get(sender);
            if let Some(r) = recovery_info {
                // when user start a recovery, set recovery status to 1
                // keep every thing else
                let r1 = Recovery {
                    status: 1,
                    recovery1_proof: "".to_string(),
                    node1_confirm: 0,
                    recovery2_proof: "".to_string(),
                    node2_confirm: 0,
                    recovery3_proof: "".to_string(),
                    node3_confirm: 0,
                    ..r
                };
                self.recoveries.insert(sender, &r1);
            }
        }

        // before user try to access its secret, call request_recovery 
        #[ink(message)]
        pub fn finish_recovery(&mut self, user: AccountId, proof: String) {
            let sender = self.env().caller();
            let user_info = self.users.get(user);
            if let Some(u) = user_info {
                let recovery_info = self.recoveries.get(user);
                if let Some(mut r) = recovery_info {
                    // when user did not start recovery before node, quit
                    if r.status != 1 {
                        return
                    }
                    if u.node1_id == sender {
                        r.node1_confirm = 1;
                        r.recovery1_proof = proof;
                    } else if u.node2_id == sender {
                        r.node2_confirm = 1;
                        r.recovery2_proof = proof;
                    } else if u.node3_id == sender {
                        r.node3_confirm = 1;
                        r.recovery3_proof = proof;
                    } else {
                    }

                    let confirm_parts = r.node1_confirm + r.node2_confirm + r.node3_confirm;
                    if confirm_parts >= 2 {
                        let r1 = Recovery {
                            r_times: r.r_times + 1,
                            status: 2,
                            ..r
                        };
                        self.recoveries.insert(user, &r1);
                        self.transfer_from_to(&user, &u.node1_id, 1);
                        self.transfer_from_to(&user, &u.node2_id, 1);
                        self.transfer_from_to(&user, &u.node3_id, 1);
                    }
                }
            }
        }


    }


    #[cfg(test)]
    mod tests {
        /// Imports all the definitions from the outer scope so we can use them here.
        use super::*;

        /// Imports `ink_lang` so we can use `#[ink::test]`.
        use ink_lang as ink;

        /// We test if the default constructor does its job.
        #[ink::test]
        fn default_works() {
            let kl = KeyLedger::default();
            let nodes = kl.get_nodes();
            assert_eq!(nodes.is_empty(), true);
        }

        /// We test a simple use case of our contract.
        #[ink::test]
        fn total_supply_works() {
            let mut kl = KeyLedger::new(30000);
            assert_eq!(kl.total_supply, 30000);
        }
    }
}
