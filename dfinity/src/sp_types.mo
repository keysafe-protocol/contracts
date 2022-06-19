/**
 * Module     : types.mo
 * Copyright  : 2021 Rocklabs
 * License    : Apache 2.0 with LLVM Exception
 * Maintainer : Rocklabs <hello@rocklabs.io>
 * Stability  : Experimental
 */

import Time "mo:base/Time";
import P "mo:base/Prelude";

module {
    /// Update call operations
    public type Operation = {
        #mint;
        #burn;
        #transfer;
        #transferFrom;
        #approve;
    };
    public type TransactionStatus = {
        #succeeded;
        #inprogress;
        #failed;
    };

    public type Node = {
        address: Principal;
        pubkey: Text;
    };

    /// Update call operation record fields
    public type TxRecord = {
        caller: ?Principal;
        op: Operation;
        index: Nat;
        from: Principal;
        to: Principal;
        amount: Nat;
        fee: Nat;
        timestamp: Time.Time;
        status: TransactionStatus;
    };

    public type User = {
        address: Principal;
        kid: Text; // primary key
        cond1Type: Int;
        cond1Address: Principal;
        cond2Type: Int;
        cond2Address: Principal;
        cond3Type: Int;
        cond3Address: Principal;
    };

    public type Recovery = {
        address: Principal;
        kid: Text; // primary key
        status: Int;
        serial: Int;
        cond1NodeProof: Text;
        cond1NodeConfirm: Int;
        cond2NodeProof: Text;
        cond2NodeConfirm: Int;
        cond3NodeProof: Text;
        cond3NodeConfirm: Int;
    }

    public func unwrap<T>(x : ?T) : T =
        switch x {
            case null { P.unreachable() };
            case (?x_) { x_ };
        };
};    
