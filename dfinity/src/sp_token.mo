/**
 * Module     : token.mo
 * Copyright  : 2021 Rocklabs
 * License    : Apache 2.0 with LLVM Exception
 * Maintainer : Rocklabs <hello@rocklabs.io>
 * Stability  : Experimental
 */

import HashMap "mo:base/HashMap";
import Principal "mo:base/Principal";
import Types "./sp_types";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Option "mo:base/Option";
import Buffer "mo:base/Buffer";
import Order "mo:base/Order";
import Nat "mo:base/Nat";
import Result "mo:base/Result";
import ExperimentalCycles "mo:base/ExperimentalCycles";


shared(msg) actor class SpToken(
    _name: Text, 
    _symbol: Text,
    _decimals: Nat8, 
    _totalSupply: Nat, 
    _owner: Principal,
    _fee: Nat
    ) {
    type Operation = Types.Operation;
    type TransactionStatus = Types.TransactionStatus;
    type TxRecord = Types.TxRecord;
    type Metadata = {
        name : Text;
        symbol : Text;
        decimals : Nat8;
        totalSupply : Nat;
        owner : Principal;
        fee : Nat;
    };
    // returns tx index or error msg
    type TxReceipt = Result.Result<Nat, {
        #InsufficientBalance;
        #InsufficientAllowance;
        #Unauthorized;
    }>;

    type Node = Types.Node;
    type User = Types.User;
    type Recovery = Types.Recovery;

    private stable var owner_ : Principal = _owner;
    private stable var name_ : Text = _name;
    private stable var decimals_ : Nat8 = _decimals;
    private stable var symbol_ : Text = _symbol;
    private stable var totalSupply_ : Nat = _totalSupply;
    private stable var blackhole : Principal = Principal.fromText("aaaaa-aa");
    private stable var feeTo : Principal = owner_;
    private stable var fee : Nat = _fee;
    private stable var balanceEntries : [(Principal, Nat)] = [];
    private stable var allowanceEntries : [(Principal, [(Principal, Nat)])] = [];
    private var balances = HashMap.HashMap<Principal, Nat>(1, Principal.equal, Principal.hash);
    private var allowances = HashMap.HashMap<Principal, HashMap.HashMap<Principal, Nat>>(1, Principal.equal, Principal.hash);

    private var nodeList = HashMap.HashMap<Principal, Text>(1, Principal.equal, Principal.hash);
    private var userList = HashMap.HashMap<Text, User>(1, Text.equal, Text.hash);
    private var recoveryList = HashMap.HashMap<Text, Recovery>(1, Text.equal, Text.hash);

    balances.put(owner_, totalSupply_);
    private stable let genesis : TxRecord = {
        caller = ?owner_;
        op = #mint;
        index = 0;
        from = blackhole;
        to = owner_;
        amount = totalSupply_;
        fee = 0;
        timestamp = Time.now();
        status = #succeeded;
    };
    private stable var ops : [TxRecord] = [genesis];

    private func addRecord(
        caller: ?Principal, op: Operation, from: Principal, to: Principal, amount: Nat,
        fee: Nat, timestamp: Time.Time, status: TransactionStatus
    ): Nat {
        let index = ops.size();
        let o : TxRecord = {
            caller = caller;
            op = op;
            index = index;
            from = from;
            to = to;
            amount = amount;
            fee = fee;
            timestamp = timestamp;
            status = status;
        };
        ops := Array.append(ops, [o]);
        return index;
    };

    private func _chargeFee(from: Principal, fee: Nat) {
        if(fee > 0) {
            _transfer(from, feeTo, fee);
        };
    };

    private func _transfer(from: Principal, to: Principal, value: Nat) {
        let from_balance = _balanceOf(from);
        let from_balance_new : Nat = from_balance - value;
        if (from_balance_new != 0) { balances.put(from, from_balance_new); }
        else { balances.delete(from); };

        let to_balance = _balanceOf(to);
        let to_balance_new : Nat = to_balance + value;
        if (to_balance_new != 0) { balances.put(to, to_balance_new); };
    };

    private func _balanceOf(who: Principal) : Nat {
        switch (balances.get(who)) {
            case (?balance) { return balance; };
            case (_) { return 0; };
        }
    };

    private func _registerNode(who: Principal, pubKey: Text) : () {
        nodeList.put(who, pubKey);
    };

    private func _registerUser(who: Principal, kid: Text, 
        cond1Type: Int, cond1Address: Principal,
        cond2Type: Int, cond2Address: Principal, 
        cond3Type: Int, cond3Address: Principal): () {
        let user : User = {
            kid = kid;
            address = who,
            cond1Type = cond1Type;
            cond1Address = cond1Address;
            cond2Type = cond2Type;
            cond2Address = cond2Address;
            cond3Type = cond3Type;
            cond3Address = cond3Address;
        };
        userList.put(kid, user);
        let recovery : Recovery = {
            address = who;
            kid = kid; // primary key
            status = 0;
            times = 0;
            cond1NodeProof = "";
            cond1NodeConfirm = 0;
            cond2NodeProof = "";
            cond2NodeConfirm = 0;
            cond3NodeProof = "";
            cond3NodeConfirm = 0;
        };
        recoveryList.put(kid, recovery);
    };

    // user call recovery start, while node call recovery finish
    private func _recoveryStart(who: Principal, kid: Text):() {
        let recovery : Recovery = recoveryList.get(kid);
        // status 1 -> user request a recovery
        recovery.status = 1;
        recoveryList.put(kid, recovery);
    };

    private func _recoveryFinish(who: Principal, kid: Text, proof: Text):() {
        let user = _getUser(kid);
        let recovery = _getRecovery(kid);
        if (recovery.status != 1) {
            return;
        }
        if (who == user.cond1Address) {
            recovery.cond1NodeProof = proof;
            recovery.cond1NodeConfirm = 1;
        };
        if (who == user.cond2Address) {
            recovery.cond2NodeProof = proof;
            recovery.cond2NodeConfirm = 1;
        };
        if (who == user.cond3Address) {
            recovery.cond3NodeProof = proof;
            recovery.cond3NodeConfirm = 1;
        };
        if (recovery.cond1NodeConfirm + recovery.cond2NodeConfirm + recovery.cond3NodeConfirm >= 2) {
            recovery.status = 2; // set status 2 indicates recovery done.
            recovery.times = recovery.times + 1;
            let userAddress = user.address;
            let node1Address = user.cond1Address;
            let node2Address = user.cond2Address;
            let node3Address = user.cond3Address;
            balance[userAddress] = balance[userAddress] - 3;
            balance[node1Address] = balance[node1Address] + 1;
            balance[node2Address] = balance[node2Address] + 1;
            balance[node3Address] = balance[node3Address] + 1;
        };
        recoveryList.put(kid, recovery);
    };

    private func _getUser(kid: Text): User {
        switch (userList.get(kid)) {
            case (?user) { return user; };
            case (_) { return null; };
        };
    };

    private func _getRecovery(kid: Text): Recovery {
        switch (recoveryList.get(kid)) {
            case (?recovery) { return recovery; };
            case (_) { return null; };
        };
    };

    private func _allowance(owner: Principal, spender: Principal) : Nat {
        switch(allowances.get(owner)) {
            case (?allowance_owner) {
                switch(allowance_owner.get(spender)) {
                    case (?allowance) { return allowance; };
                    case (_) { return 0; };
                }
            };
            case (_) { return 0; };
        }
    };

    /*
    *   Core interfaces: 
    *       update calls: 
    *           transfer/transferFrom/approve
    *       query calls: 
    *           logo/name/symbol/decimal/totalSupply/balanceOf/allowance/getMetadata
    *           historySize/getTransaction/getTransactions
    */

    /// Transfers value amount of tokens to Principal to.
    public shared(msg) func transfer(to: Principal, value: Nat) : async TxReceipt {
        if (_balanceOf(msg.caller) < value + fee) { return #err(#InsufficientBalance); };
        _chargeFee(msg.caller, fee);
        _transfer(msg.caller, to, value);
        let txid = addRecord(null, #transfer, msg.caller, to, value, fee, Time.now(), #succeeded);
        return #ok(txid);
    };

    /// Transfers value amount of tokens from Principal from to Principal to.
    public shared(msg) func transferFrom(from: Principal, to: Principal, value: Nat) : async TxReceipt {
        if (_balanceOf(from) < value + fee) { return #err(#InsufficientBalance); };
        let allowed : Nat = _allowance(from, msg.caller);
        if (allowed < value + fee) { return #err(#InsufficientAllowance); };
        _chargeFee(from, fee);
        _transfer(from, to, value);
        let allowed_new : Nat = allowed - value - fee;
        if (allowed_new != 0) {
            let allowance_from = Types.unwrap(allowances.get(from));
            allowance_from.put(msg.caller, allowed_new);
            allowances.put(from, allowance_from);
        } else {
            if (allowed != 0) {
                let allowance_from = Types.unwrap(allowances.get(from));
                allowance_from.delete(msg.caller);
                if (allowance_from.size() == 0) { allowances.delete(from); }
                else { allowances.put(from, allowance_from); };
            };
        };
        let txid = addRecord(?msg.caller, #transferFrom, from, to, value, fee, Time.now(), #succeeded);
        return #ok(txid);
    };

    /// Allows spender to withdraw from your account multiple times, up to the value amount. 
    /// If this function is called again it overwrites the current allowance with value.
    public shared(msg) func approve(spender: Principal, value: Nat) : async TxReceipt {
        if(_balanceOf(msg.caller) < fee) { return #err(#InsufficientBalance); };
        _chargeFee(msg.caller, fee);
        let v = value + fee;
        if (value == 0 and Option.isSome(allowances.get(msg.caller))) {
            let allowance_caller = Types.unwrap(allowances.get(msg.caller));
            allowance_caller.delete(spender);
            if (allowance_caller.size() == 0) { allowances.delete(msg.caller); }
            else { allowances.put(msg.caller, allowance_caller); };
        } else if (value != 0 and Option.isNull(allowances.get(msg.caller))) {
            var temp = HashMap.HashMap<Principal, Nat>(1, Principal.equal, Principal.hash);
            temp.put(spender, v);
            allowances.put(msg.caller, temp);
        } else if (value != 0 and Option.isSome(allowances.get(msg.caller))) {
            let allowance_caller = Types.unwrap(allowances.get(msg.caller));
            allowance_caller.put(spender, v);
            allowances.put(msg.caller, allowance_caller);
        };
        let txid = addRecord(null, #approve, msg.caller, spender, v, fee, Time.now(), #succeeded);
        return #ok(txid);
    };

    public shared(msg) func mint(to: Principal, amount: Nat): async TxReceipt {
        if(msg.caller != owner_) {
            return #err(#Unauthorized);
        };
        let to_balance = _balanceOf(to);
        totalSupply_ += amount;
        balances.put(to, to_balance + amount);
        let txid = addRecord(?msg.caller, #mint, blackhole, to, amount, 0, Time.now(), #succeeded);
        return #ok(txid);
    };


    // node invoke this API to report itself is currently running a shuttle service
    // and is ready to store user secret shards
    public shared(msg) func registerNode(pubKey: Text): () {
        _registerNode(msg.caller, pubKey);
    };

    // user invoke this API to report a register completed
    // when all nodes that are storing one's secret shards
    public shared(msg) func registerUser(kid: Text, 
        cond1Type: Int, cond1Address: Principal,
        cond2Type: Int, cond2Address: Principal, 
        cond3Type: Int, cond3Address: Principal): () {
        _registerUser(msg.caller, kid, cond1Type, cond1Address,
            cond2Type, cond2Address, cond3Type, cond3Address);
    }


    // user invoke this API to report starting a recovery for oneself
    public shared(msg) func recoveryStart(kid: Text):() {
        _recoveryStart(msg.caller, kid);
    }

    // shuttle-protocol node invoke this API to report finishing a recovery for user
    // when 2/3 recoveries are done, all 3 node that are holding user secret shards will be rewarded
    public shared(msg) func recoveryFinish(kid: Text, proof: Text):() {
        _recoveryFinish(msg.caller, kid, proof);
    }

    
    public shared(msg) func burn(amount: Nat): async TxReceipt {
        let from_balance = _balanceOf(msg.caller);
        if(from_balance < amount) {
            return #err(#InsufficientBalance);
        };
        totalSupply_ -= amount;
        balances.put(msg.caller, from_balance - amount);
        let txid = addRecord(?msg.caller, #burn, msg.caller, blackhole, amount, 0, Time.now(), #succeeded);
        return #ok(txid);
    };

    public query func name() : async Text {
        return name_;
    };

    public query func symbol() : async Text {
        return symbol_;
    };

    public query func decimals() : async Nat8 {
        return decimals_;
    };

    public query func totalSupply() : async Nat {
        return totalSupply_;
    };

    public query func getTokenFee() : async Nat {
        return fee;
    };

    public query func balanceOf(who: Principal) : async Nat {
        return _balanceOf(who);
    };

    public query func allowance(owner: Principal, spender: Principal) : async Nat {
        return _allowance(owner, spender);
    };

    public query func getMetadata() : async Metadata {
        return {
            name = name_;
            symbol = symbol_;
            decimals = decimals_;
            totalSupply = totalSupply_;
            owner = owner_;
            fee = fee;
        };
    };

    /// Get transaction history size
    public query func historySize() : async Nat {
        return ops.size();
    };

    /// Get transaction by index.
    public query func getTransaction(index: Nat) : async TxRecord {
        return ops[index];
    };

    /// Get history
    public query func getTransactions(start: Nat, limit: Nat) : async [TxRecord] {
        var ret: Buffer.Buffer<TxRecord> = Buffer.Buffer(1024);
        var i = start;
        while(i < start + limit and i < ops.size()) {
            ret.add(ops[i]);
            i += 1;
        };
        return ret.toArray();
    };

    public query func getNodeList(): async [Node] {
        var ret: Buffer.Buffer<Node> = Buffer.Buffer(1024);
        for ((k, v) in nodeList.entries()) {
            let n : Node = {
                address = k;
                pubkey = v;
            };
            ret.add(n);
        };
        return ret.toArray();
    };

    /*
    *   Optional interfaces:
    *       setLogo/setFee/setFeeTo/setOwner
    *       getUserTransactionsAmount/getUserTransactions
    *       getTokenInfo/getHolders/getUserApprovals
    */

    public shared(msg) func setFeeTo(to: Principal) {
        assert(msg.caller == owner_);
        feeTo := to;
    };

    public shared(msg) func setFee(_fee: Nat) {
        assert(msg.caller == owner_);
        fee := _fee;
    };

    public shared(msg) func setOwner(_owner: Principal) {
        assert(msg.caller == owner_);
        owner_ := _owner;
    };

    public query func getUserTransactionAmount(a: Principal) : async Nat {
        var res: Nat = 0;
        for (i in ops.vals()) {
            if (i.caller == ?a or i.from == a or i.to == a) {
                res += 1;
            };
        };
        return res;
    };

    public query func getUserTransactions(a: Principal, start: Nat, limit: Nat) : async [TxRecord] {
        var res: Buffer.Buffer<TxRecord> = Buffer.Buffer(1024);
        var index: Nat = 0;
        for (i in ops.vals()) {
            if (i.caller == ?a or i.from == a or i.to == a) {
                if(index >= start and index < start + limit) {
                    res.add(i);
                };
                index += 1;
            };
        };
        return res.toArray();
    };

    public type TokenInfo = {
        metadata: Metadata;
        feeTo: Principal;
        // status info
        historySize: Nat;
        deployTime: Time.Time;
        holderNumber: Nat;
        cycles: Nat;
    };
    public query func getTokenInfo(): async TokenInfo {
        {
            metadata = {
                name = name_;
                symbol = symbol_;
                decimals = decimals_;
                totalSupply = totalSupply_;
                owner = owner_;
                fee = fee;
            };
            feeTo = feeTo;
            historySize = ops.size();
            deployTime = genesis.timestamp;
            holderNumber = balances.size();
            cycles = ExperimentalCycles.balance();
        }
    };

    public query func getHolders(start: Nat, limit: Nat) : async [(Principal, Nat)] {
        let temp =  Iter.toArray(balances.entries());
        func order (a: (Principal, Nat), b: (Principal, Nat)) : Order.Order {
            return Nat.compare(b.1, a.1);
        };
        let sorted = Array.sort(temp, order);
        let limit_: Nat = if(start + limit > temp.size()) {
            temp.size() - start
        } else {
            limit
        };
        let res = Array.init<(Principal, Nat)>(limit_, (owner_, 0));
        for (i in Iter.range(0, limit_ - 1)) {
            res[i] := sorted[i+start];
        };
        return Array.freeze(res);
    };

    public query func getAllowanceSize() : async Nat {
        var size : Nat = 0;
        for ((k, v) in allowances.entries()) {
            size += v.size();
        };
        return size;   
    };

    public query func getUserApprovals(who : Principal) : async [(Principal, Nat)] {
        switch (allowances.get(who)) {
            case (?allowance_who) {
                return Iter.toArray(allowance_who.entries());
            };
            case (_) {
                return [];
            };
        }
    };

    /*
    * upgrade functions
    */
    system func preupgrade() {
        balanceEntries := Iter.toArray(balances.entries());
        var size : Nat = allowances.size();
        var temp : [var (Principal, [(Principal, Nat)])] = Array.init<(Principal, [(Principal, Nat)])>(size, (owner_, []));
        size := 0;
        for ((k, v) in allowances.entries()) {
            temp[size] := (k, Iter.toArray(v.entries()));
            size += 1;
        };
        allowanceEntries := Array.freeze(temp);
    };

    system func postupgrade() {
        balances := HashMap.fromIter<Principal, Nat>(balanceEntries.vals(), 1, Principal.equal, Principal.hash);
        balanceEntries := [];
        for ((k, v) in allowanceEntries.vals()) {
            let allowed_temp = HashMap.fromIter<Principal, Nat>(v.vals(), 1, Principal.equal, Principal.hash);
            allowances.put(k, allowed_temp);
        };
        allowanceEntries := [];
    };
};
