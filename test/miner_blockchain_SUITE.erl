-module(miner_blockchain_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("blockchain/include/blockchain_vars.hrl").
-include("miner_ct_macros.hrl").

-export([
         init_per_suite/1,
         end_per_suite/1,
         init_per_testcase/2,
         end_per_testcase/2,
         all/0

        ]).

-compile([export_all]).

%% common test callbacks

all() -> [
          restart_test,
          dkg_restart_test,
          election_test,
          election_multi_test,
          group_change_test,
          master_key_test,
          version_change_test,
          election_v3_test,
          %% this is an OK smoke test but doesn't hit every time, the
          %% high test is more reliable
          %% snapshot_test,
          high_snapshot_test
         ].

init_per_suite(Config) ->
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(TestCase, Config0) ->
    Config = miner_ct_utils:init_per_testcase(?MODULE, TestCase, Config0),
    try
    Miners = ?config(miners, Config),
    Addresses = ?config(addresses, Config),

    NumConsensusMembers = ?config(num_consensus_members, Config),
    BlockTime = case TestCase of
                    restart_test ->
                        3000;
                    _ ->
                        ?config(block_time, Config)
                end,
    Interval = ?config(election_interval, Config),
    BatchSize = ?config(batch_size, Config),
    Curve = ?config(dkg_curve, Config),

    #{secret := Priv, public := Pub} = Keys =
        libp2p_crypto:generate_keys(ecc_compact),

    Extras =
        case TestCase of
            dkg_restart_test ->
                #{?election_interval => 10,
                  ?election_restart_interval => 99};
            T when T == snapshot_test;
                   T == high_snapshot_test;
                   T == group_change_test ->
                #{?snapshot_version => 1,
                  ?snapshot_interval => 5,
                  ?election_bba_penalty => 0.01,
                  ?election_seen_penalty => 0.05,
                  ?election_version => 3};
            election_v3_test ->
                #{
                  ?election_version => 2
                 };
            _ ->
                #{}
        end,

    Vars = #{garbage_value => totes_garb,
             ?block_time => max(1500, BlockTime),
             ?election_interval => Interval,
             ?num_consensus_members => NumConsensusMembers,
             ?batch_size => BatchSize,
             ?dkg_curve => Curve},
    FinalVars = maps:merge(Vars, Extras),
    ct:pal("final vars ~p", [FinalVars]),

    InitialVars =
        case TestCase of
            version_change_test ->
                miner_ct_utils:make_vars(Keys, FinalVars, legacy);
            _ ->
                miner_ct_utils:make_vars(Keys, FinalVars)
        end,

    InitialPayment = [ blockchain_txn_coinbase_v1:new(Addr, 5000) || Addr <- Addresses],
    Locations = lists:foldl(
        fun(I, Acc) ->
            [h3:from_geo({37.780586, -122.469470 + I/50}, 13)|Acc]
        end,
        [],
        lists:seq(1, length(Addresses))
    ),
    InitGen = [blockchain_txn_gen_gateway_v1:new(Addr, Addr, Loc, 0) || {Addr, Loc} <- lists:zip(Addresses, Locations)],
    Txns = InitialVars ++ InitialPayment ++ InitGen,

    {ok, DKGCompletedNodes} = miner_ct_utils:initial_dkg(Miners, Txns, Addresses, NumConsensusMembers, Curve),

    %% integrate genesis block
    _GenesisLoadResults = miner_ct_utils:integrate_genesis_block(hd(DKGCompletedNodes), Miners -- DKGCompletedNodes),

    {ConsensusMiners, NonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),
    ct:pal("ConsensusMiners: ~p, NonConsensusMiners: ~p", [ConsensusMiners, NonConsensusMiners]),

    ok = miner_ct_utils:wait_for_gte(height, Miners, 3, all, 15),

    [   {master_key, {Priv, Pub}},
        {consensus_miners, ConsensusMiners},
        {non_consensus_miners, NonConsensusMiners}
        | Config]
    catch
        What:Why:Stack ->
            end_per_testcase(TestCase, Config),
            ct:pal("Stack ~p", [Stack]),
            erlang:What(Why)
    end.

end_per_testcase(_TestCase, Config) ->
    miner_ct_utils:end_per_testcase(_TestCase, Config).



restart_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    Miners = ?config(miners, Config),

    %% wait till the chain reaches height 2 for all miners
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 60),

    Env = miner_ct_utils:stop_miners(lists:sublist(Miners, 1, 2)),

    [begin
          ct_rpc:call(Miner, miner_consensus_mgr, cancel_dkg, [], 300)
     end
     || Miner <- lists:sublist(Miners, 3, 4)],

    %% just kill the consensus groups, we should be able to restore them
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_*{1,2}*", "/blockchain_swarm/groups/consensus_*"),

    ok = miner_ct_utils:start_miners(Env),

    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 90),

    Heights =  miner_ct_utils:heights(Miners),

    {comment, Heights}.


dkg_restart_test(Config) ->
    Miners = ?config(miners, Config),
    Interval = ?config(election_interval, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    %% stop the out of consensus miners and the last two consensus
    %% members.  this should keep the dkg from completing
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, any, 90), % wait up to 90s for epoch to or exceed 2

    Members = miner_ct_utils:consensus_members(2, Miners),

    %% there are issues with this.  if it's more of a problem than the
    %% last time, we can either have the old list and reject it if we
    %% get it again, or we get all of them and select the majority one?
    {CMiners, NCMiners} = miner_ct_utils:partition_miners(Members, AddrList),
    FirstCMiner = hd(CMiners),
    Height = miner_ct_utils:height(FirstCMiner),
    Stoppers = lists:sublist(CMiners, 5, 2),
    %% make sure that everyone has accepted the epoch block
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + 2),

    Stop1 = miner_ct_utils:stop_miners(NCMiners ++ Stoppers, 60),
    ct:pal("stopping nc ~p stoppers ~p", [NCMiners, Stoppers]),

    %% wait until we're sure that the election is running
    ok = miner_ct_utils:wait_for_gte(height, lists:sublist(CMiners, 1, 4), Height + (Interval * 2), all, 180),

    %% stop half of the remaining miners
    Restarters = lists:sublist(CMiners, 1, 2),
    ct:pal("stopping restarters ~p", [Restarters]),
    Stop2 = miner_ct_utils:stop_miners(Restarters, 60),

    %% restore that half
    ct:pal("starting restarters ~p", [Restarters]),
    miner_ct_utils:start_miners(Stop2, 60),

    %% restore the last two
    ct:pal("starting blockers"),
    miner_ct_utils:start_miners(Stop1, 60),

    %% make sure that we elect again
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 3, any, 90),

    %% make sure that we did the restore
    EndHeight = miner_ct_utils:height(FirstCMiner),
    ?assert(EndHeight < (Height + Interval + 99)).

election_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    %% get all the miners
    Miners = ?config(miners, Config),
    AddrList = ?config(tagged_miner_addresses, Config),

    Me = self(),
    spawn(miner_ct_utils, election_check, [Miners, Miners, AddrList, Me]),

    fun Loop(0) ->
            error(seen_timeout);
        Loop(N) ->
            receive
                seen_all ->
                    ok;
                {not_seen, []} ->
                    ok;
                {not_seen, Not} ->
                    Miner = lists:nth(rand:uniform(length(Miners)), Miners),
                    try
                        Height = miner_ct_utils:height(Miner),
                        {_, _, Epoch} = ct_rpc:call(Miner, miner_cli_info, get_info, [], 500),
                        ct:pal("not seen: ~p height ~p epoch ~p", [Not, Height, Epoch])
                    catch _:_ ->
                            ct:pal("not seen: ~p ", [Not]),
                            ok
                    end,
                    timer:sleep(100),
                    Loop(N - 1)
            after timer:seconds(30) ->
                    error(message_timeout)
            end
    end(60),

    %% we've seen all of the nodes, yay.  now make sure that more than
    %% one election can happen.
    %% we wait until we have seen all miners hit an epoch of 3
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 3, all, 90),

    %% stop the first 4 miners
    TargetMiners = lists:sublist(Miners, 1, 4),
    Stop = miner_ct_utils:stop_miners(TargetMiners),

    ct:pal("stopped, waiting"),

    %% confirm miner is stopped
    ok = miner_ct_utils:wait_for_app_stop(TargetMiners, miner),

    %% delete the groups
    timer:sleep(1000),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),

    ct:pal("stopped and deleted"),

    %% start the stopped miners back up again
    miner_ct_utils:start_miners(Stop),

    %% second: make sure we're not making blocks anymore
    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    %% height might go up by one, but it should not go up by 5
    {_, false} = miner_ct_utils:wait_for_gte(height, Miners, Height + 5, any, 10),

    %% third: mint and submit the rescue txn, shrinking the group at
    %% the same time.

    Addresses = ?config(addresses, Config),
    NewGroup = lists:sublist(Addresses, 3, 4),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, HeadBlock} = ct_rpc:call(hd(Miners), blockchain, head_block, [HChain2]),

    NewHeight = blockchain_block:height(HeadBlock) + 1,
    ct:pal("new height is ~p", [NewHeight]),
    Hash = blockchain_block:hash_block(HeadBlock),

    Vars = #{?num_consensus_members => 4},

    {Priv, _Pub} = ?config(master_key, Config),

    Txn = blockchain_txn_vars_v1:new(Vars, 3),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    VarsTxn = blockchain_txn_vars_v1:proof(Txn, Proof),

    {ElectionEpoch, _EpochStart} = blockchain_block_v1:election_info(HeadBlock),
    ct:pal("current election epoch: ~p new height: ~p", [ElectionEpoch, NewHeight]),

    GrpTxn = blockchain_txn_consensus_group_v1:new(NewGroup, <<>>, Height, 0),

    RescueBlock = blockchain_block_v1:rescue(
                    #{prev_hash => Hash,
                      height => NewHeight,
                      transactions => [VarsTxn, GrpTxn],
                      hbbft_round => NewHeight,
                      time => erlang:system_time(seconds),
                      election_epoch => ElectionEpoch + 1,
                      epoch_start => NewHeight}),

    EncodedBlock = blockchain_block:serialize(
                     blockchain_block_v1:set_signatures(RescueBlock, [])),

    RescueSigFun = libp2p_crypto:mk_sig_fun(Priv),

    RescueSig = RescueSigFun(EncodedBlock),

    SignedBlock = blockchain_block_v1:set_signatures(RescueBlock, [], RescueSig),

    %% now that we have a signed block, cause one of the nodes to
    %% absorb it (and gossip it around)
    FirstNode = hd(Miners),
    Chain = ct_rpc:call(FirstNode, blockchain_worker, blockchain, []),
    ct:pal("FirstNode Chain: ~p", [Chain]),
    Swarm = ct_rpc:call(FirstNode, blockchain_swarm, swarm, []),
    ct:pal("FirstNode Swarm: ~p", [Swarm]),
    N = length(Miners),
    ct:pal("N: ~p", [N]),
    ok = ct_rpc:call(FirstNode, blockchain_gossip_handler, add_block, [SignedBlock, Chain, self(), blockchain_swarm:tid()]),

    %% wait until height has increased by 3
    ok = miner_ct_utils:wait_for_gte(height, Miners, NewHeight + 2),

    %% check consensus and non consensus miners
    {NewConsensusMiners, NewNonConsensusMiners} = miner_ct_utils:miners_by_consensus_state(Miners),

    %% stop some nodes and restart them to check group restore works
    StopList = lists:sublist(NewConsensusMiners, 2) ++ lists:sublist(NewNonConsensusMiners, 2),
    ct:pal("stop list ~p", [StopList]),
    Stop2 = miner_ct_utils:stop_miners(StopList),

    %% sleep a lil then start the nodes back up again
    timer:sleep(1000),

    miner_ct_utils:start_miners(Stop2),

    %% fourth: confirm that blocks and elections are proceeding
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, ElectionEpoch + 1).

election_multi_test(Config) ->
    BaseDir = ?config(base_dir, Config),
    %% get all the miners
    Miners = ?config(miners, Config),
    %% AddrList = ?config(tagged_miner_addresses, Config),
    Addresses = ?config(addresses, Config),
    {Priv, _Pub} = ?config(master_key, Config),

    %% we wait until we have seen all miners hit an epoch of 2
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2, all, 90),

    ct:pal("starting multisig attempt"),

    #{secret := Priv1, public := Pub1} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv2, public := Pub2} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv3, public := Pub3} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv4, public := Pub4} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv5, public := Pub5} = libp2p_crypto:generate_keys(ecc_compact),
    BinPub1 = libp2p_crypto:pubkey_to_bin(Pub1),
    BinPub2 = libp2p_crypto:pubkey_to_bin(Pub2),
    BinPub3 = libp2p_crypto:pubkey_to_bin(Pub3),
    BinPub4 = libp2p_crypto:pubkey_to_bin(Pub4),
    BinPub5 = libp2p_crypto:pubkey_to_bin(Pub5),

    Txn7_0 = blockchain_txn_vars_v1:new(
               #{?use_multi_keys => true}, 2,
               #{multi_keys => [BinPub1, BinPub2, BinPub3, BinPub4, BinPub5]}),
    Proofs7 = [blockchain_txn_vars_v1:create_proof(P, Txn7_0)
               || P <- [Priv1, Priv2, Priv3, Priv4, Priv5]],
    Txn7_1 = blockchain_txn_vars_v1:multi_key_proofs(Txn7_0, Proofs7),
    Proof7 = blockchain_txn_vars_v1:create_proof(Priv, Txn7_1),
    Txn7 = blockchain_txn_vars_v1:proof(Txn7_1, Proof7),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn7]) || M <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?use_multi_keys, true),
    ct:pal("transitioned to multikey"),

    %% stop the first 4 miners
    TargetMiners = lists:sublist(Miners, 1, 4),
    Stop = miner_ct_utils:stop_miners(TargetMiners),

    %% confirm miner is stopped
    ok = miner_ct_utils:wait_for_app_stop(TargetMiners, miner),

    %% delete the groups
    timer:sleep(1000),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),
    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_{1,2,3,4}*/blockchain_swarm/groups/*", ""),

    %% start the stopped miners back up again
    miner_ct_utils:start_miners(Stop),

    NewAddrs =
        [begin
             Swarm = ct_rpc:call(Target, blockchain_swarm, swarm, [], 2000),
             [H|_] = LAs= ct_rpc:call(Target, libp2p_swarm, listen_addrs, [Swarm], 2000),
             ct:pal("addrs ~p ~p", [Target, LAs]),
             H
         end || Target <- TargetMiners],

    miner_ct_utils:pmap(
      fun(M) ->
              [begin
                   Sw = ct_rpc:call(M, blockchain_swarm, swarm, [], 2000),
                   ct_rpc:call(M, libp2p_swarm, connect, [Sw, Addr], 2000)
               end || Addr <- NewAddrs]
      end, Miners),

    %% second: make sure we're not making blocks anymore
    HChain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height1} = ct_rpc:call(hd(Miners), blockchain, height, [HChain1]),

    %% height might go up by one, but it should not go up by 5
    {_, false} = miner_ct_utils:wait_for_gte(height, Miners, Height1 + 5, any, 10),

    HeadAddress = ct_rpc:call(hd(Miners), blockchain_swarm, pubkey_bin, []),

    GroupTail = Addresses -- [HeadAddress],
    ct:pal("l ~p tail ~p", [length(GroupTail), GroupTail]),

    {NewHeight, HighBlock} =
        lists:max(
          [begin
               C = ct_rpc:call(M, blockchain_worker, blockchain, []),
               {ok, HB} = ct_rpc:call(M, blockchain, head_block, [C]),
               {blockchain_block:height(HB) + 1, HB}
           end || M <- Miners]),
    ct:pal("new height is ~p", [NewHeight]),

    Hash2 = blockchain_block:hash_block(HighBlock),
    {ElectionEpoch1, _EpochStart1} = blockchain_block_v1:election_info(HighBlock),
    GrpTxn2 = blockchain_txn_consensus_group_v1:new(GroupTail, <<>>, NewHeight, 0),

    RescueBlock2 =
        blockchain_block_v1:rescue(
                    #{prev_hash => Hash2,
                      height => NewHeight,
                      transactions => [GrpTxn2],
                      hbbft_round => NewHeight,
                      time => erlang:system_time(seconds),
                      election_epoch => ElectionEpoch1 + 1,
                      epoch_start => NewHeight}),

    EncodedBlock2 = blockchain_block:serialize(
                      blockchain_block_v1:set_signatures(RescueBlock2, [])),

    RescueSigs =
        [begin
             RescueSigFun2 = libp2p_crypto:mk_sig_fun(P),

             RescueSigFun2(EncodedBlock2)
         end
         || P <- [Priv1, Priv2, Priv3, Priv4, Priv5]],

    SignedBlock = blockchain_block_v1:set_signatures(RescueBlock2, [], RescueSigs),

    %% now that we have a signed block, cause one of the nodes to
    %% absorb it (and gossip it around)
    FirstNode = hd(Miners),
    SecondNode = lists:last(Miners),
    Chain1 = ct_rpc:call(FirstNode, blockchain_worker, blockchain, []),
    Chain2 = ct_rpc:call(SecondNode, blockchain_worker, blockchain, []),
    N = length(Miners),
    ct:pal("first node ~p second ~pN: ~p", [FirstNode, SecondNode, N]),
    ok = ct_rpc:call(FirstNode, blockchain_gossip_handler, add_block, [SignedBlock, Chain1, self(), blockchain_swarm:tid()]),
    ok = ct_rpc:call(SecondNode, blockchain_gossip_handler, add_block, [SignedBlock, Chain2, self(), blockchain_swarm:tid()]),

    %% wait until height has increased
    case miner_ct_utils:wait_for_gte(height, Miners, NewHeight + 3, any, 30) of
        ok -> ok;
        _ ->
            [begin
                 Status = ct_rpc:call(M, miner, hbbft_status, []),
                 ct:pal("miner ~p, status: ~p", [M, Status])
             end
             || M <- Miners],
            error(rescue_group_made_no_progress)
    end.

group_change_test(Config) ->
    %% get all the miners
    Miners = ?config(miners, Config),
    BaseDir = ?config(base_dir, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(4, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),

    %% submit the transaction

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger1 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain1]),
    ?assertEqual({ok, totes_garb}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger1])),

    Vars = #{num_consensus_members => 7},

    {Priv, _Pub} = ?config(master_key, Config),

    Txn = blockchain_txn_vars_v1:new(Vars, 2, #{version_predicate => 2,
                                                unsets => [garbage_value]}),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:proof(Txn, Proof),

    %% wait for it to take effect
    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1])
         || Miner <- Miners],

    HChain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height} = ct_rpc:call(hd(Miners), blockchain, height, [HChain]),

    %% wait until height has increased by 20
    ok = miner_ct_utils:wait_for_gte(height, Miners, Height + 20, all, 80),

    [{Target, TargetEnv}] = miner_ct_utils:stop_miners([lists:last(Miners)]),

    Miners1 = Miners -- [Target],

    ct:pal("stopped target: ~p", [Target]),

    %% make sure we still haven't executed it
    C = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    L = ct_rpc:call(hd(Miners), blockchain, ledger, [C]),
    {ok, Members} = ct_rpc:call(hd(Miners), blockchain_ledger_v1, consensus_members, [L]),
    ?assertEqual(4, length(Members)),

    %% take a snapshot to load *before* the threshold is processed
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {SnapshotBlockHeight, _SnapshotBlockHash, SnapshotHash} =
        ct_rpc:call(hd(Miners), blockchain, find_last_snapshot, [Chain]),

    %% alter the "version" for all of them that are up.
    lists:foreach(
      fun(Miner) ->
              ct_rpc:call(Miner, miner, inc_tv, [rand:uniform(4)]) %% make sure we're exercising the summing
      end, Miners1),

    true = miner_ct_utils:wait_until(
             fun() ->
                     lists:all(
                       fun(Miner) ->
                               NewVersion = ct_rpc:call(Miner, miner, test_version, [], 1000),
                               ct:pal("test version ~p ~p", [Miner, NewVersion]),
                               NewVersion > 1
                       end, Miners1)
             end),

    %% wait for the change to take effect
    Timeout = 200,
    true = miner_ct_utils:wait_until(
             fun() ->
                     lists:all(
                       fun(Miner) ->
                               C1 = ct_rpc:call(Miner, blockchain_worker, blockchain, [], Timeout),
                               L1 = ct_rpc:call(Miner, blockchain, ledger, [C1], Timeout),
                               case ct_rpc:call(Miner, blockchain, config, [num_consensus_members, L1], Timeout) of
                                   {ok, Sz} ->
                                       ct:pal("size = ~p", [Sz]),
                                       Sz == 7;
                                   _ ->
                                       %% badrpc
                                       false
                               end
                       end, Miners1)
             end, 120, 1000),

    ok = miner_ct_utils:delete_dirs(BaseDir ++ "_*{8}*/*", ""),
    [EightDir] = filelib:wildcard(BaseDir ++ "_*{8}*"),

    BlockchainR = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, GenesisBlock} = ct_rpc:call(hd(Miners), blockchain, genesis_block, [BlockchainR]),

    GenSer = blockchain_block:serialize(GenesisBlock),
    ok = file:make_dir(EightDir ++ "/update"),
    ok = file:write_file(EightDir ++ "/update/genesis", GenSer),

    %% clean out everything from the stopped node

    BlockchainEnv = proplists:get_value(blockchain, TargetEnv),
    NewBlockchainEnv = [{blessed_snapshot_block_hash, SnapshotHash}, {blessed_snapshot_block_height, SnapshotBlockHeight},
                        {quick_sync_mode, blessed_snapshot}, {honor_quick_sync, true}|BlockchainEnv],

    MinerEnv = proplists:get_value(miner, TargetEnv),
    NewMinerEnv = [{update_dir, EightDir ++ "/update"} | MinerEnv],

    NewTargetEnv0 = lists:keyreplace(blockchain, 1, TargetEnv, {blockchain, NewBlockchainEnv}),
    NewTargetEnv = lists:keyreplace(miner, 1, NewTargetEnv0, {miner, NewMinerEnv}),

    %% restart it
    miner_ct_utils:start_miners([{Target, NewTargetEnv}]),

    Swarm = ct_rpc:call(Target, blockchain_swarm, swarm, [], 2000),
    [H|_] = ct_rpc:call(Target, libp2p_swarm, listen_addrs, [Swarm], 2000),

    miner_ct_utils:pmap(
      fun(M) ->
              Sw = ct_rpc:call(M, blockchain_swarm, swarm, [], 2000),
              ct_rpc:call(M, libp2p_swarm, connect, [Sw, H], 2000)
      end, Miners1),

    Blockchain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    Ledger2 = ct_rpc:call(hd(Miners), blockchain, ledger, [Blockchain2]),
    ?assertEqual({error, not_found}, ct_rpc:call(hd(Miners), blockchain, config, [garbage_value, Ledger2])),

    HChain2 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {ok, Height2} = ct_rpc:call(hd(Miners), blockchain, height, [HChain2]),

    ct:pal("post change miner ~p height ~p", [hd(Miners), Height2]),
    %% TODO: probably need to parameterize this via the delay
    ?assert(Height2 > Height + 20 + 10),

    %% do some additional checks to make sure that we restored across.

    ok = miner_ct_utils:wait_for_gte(height, [Target], Height2, all, 120),

    TC = ct_rpc:call(Target, blockchain_worker, blockchain, [], Timeout),
    TL = ct_rpc:call(Target, blockchain, ledger, [TC], Timeout),
    {ok, TSz} = ct_rpc:call(Target, blockchain, config, [num_consensus_members, TL], Timeout),
    ?assertEqual(TSz, 7),

    ok.

master_key_test(Config) ->
    %% get all the miners
    Miners = ?config(miners, Config),

    %% baseline: chain vars are working
    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Txn1_0 = blockchain_txn_vars_v1:new(Vars, 2),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn1_0),
    Txn1_1 = blockchain_txn_vars_v1:proof(Txn1_0, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1_1]) || Miner <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, totes_goats_garb),

    %% bad master key

    #{secret := Priv2, public := Pub2} =
        libp2p_crypto:generate_keys(ecc_compact),

    BinPub2 = libp2p_crypto:pubkey_to_bin(Pub2),

    Vars2 = #{garbage_value => goats_are_not_garb},
    Txn2_0 = blockchain_txn_vars_v1:new(Vars2, 3, #{master_key => BinPub2}),
    Proof2 = blockchain_txn_vars_v1:create_proof(Priv, Txn2_0),
    KeyProof2 = blockchain_txn_vars_v1:create_proof(Priv2, Txn2_0),
    KeyProof2Corrupted = <<Proof2/binary, "asdasdasdas">>,
    Txn2_1 = blockchain_txn_vars_v1:proof(Txn2_0, Proof2),
    Txn2_2c = blockchain_txn_vars_v1:key_proof(Txn2_1, KeyProof2Corrupted),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_2c]) || Miner <- Miners],

    %% and then confirm the transaction did not apply
    false = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb, 10),

    %% good master key

    Txn2_2 = blockchain_txn_vars_v1:key_proof(Txn2_1, KeyProof2),
    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_2])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    %% make sure old master key is no longer working

    Vars4 = #{garbage_value => goats_are_too_garb},
    Txn4_0 = blockchain_txn_vars_v1:new(Vars4, 4),
    Proof4 = blockchain_txn_vars_v1:create_proof(Priv, Txn4_0),
    Txn4_1 = blockchain_txn_vars_v1:proof(Txn4_0, Proof4),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn4_1])
         || Miner <- Miners],

    false = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_too_garb, 10),

    %% double check that new master key works

    Vars5 = #{garbage_value => goats_always_win},
    Txn5_0 = blockchain_txn_vars_v1:new(Vars5, 4),
    Proof5 = blockchain_txn_vars_v1:create_proof(Priv2, Txn5_0),
    Txn5_1 = blockchain_txn_vars_v1:proof(Txn5_0, Proof5),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn5_1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_always_win),

    %% test all the multikey stuff

    %% first enable them
    Txn6 = vars(#{?use_multi_keys => true}, 5, Priv2),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn6]) || M <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?use_multi_keys, true),

    #{secret := Priv3, public := Pub3} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv4, public := Pub4} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv5, public := Pub5} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv6, public := Pub6} = libp2p_crypto:generate_keys(ecc_compact),
    #{secret := Priv7, public := Pub7} = libp2p_crypto:generate_keys(ecc_compact),
    BinPub3 = libp2p_crypto:pubkey_to_bin(Pub3),
    BinPub4 = libp2p_crypto:pubkey_to_bin(Pub4),
    BinPub5 = libp2p_crypto:pubkey_to_bin(Pub5),
    BinPub6 = libp2p_crypto:pubkey_to_bin(Pub6),
    BinPub7 = libp2p_crypto:pubkey_to_bin(Pub7),

    Txn7_0 = blockchain_txn_vars_v1:new(
               #{garbage_value => goat_jokes_are_so_single_key}, 6,
               #{multi_keys => [BinPub2, BinPub3, BinPub4, BinPub5, BinPub6]}),
    Proofs7 = [blockchain_txn_vars_v1:create_proof(P, Txn7_0)
               %% shuffle the proofs to make sure we no longer need
               %% them in the correct order
               || P <- miner_ct_utils:shuffle([Priv2, Priv3, Priv4, Priv5, Priv6])],
    Txn7_1 = blockchain_txn_vars_v1:multi_key_proofs(Txn7_0, Proofs7),
    Proof7 = blockchain_txn_vars_v1:create_proof(Priv2, Txn7_1),
    Txn7 = blockchain_txn_vars_v1:proof(Txn7_1, Proof7),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn7]) || M <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goat_jokes_are_so_single_key),

    %% try with only three keys (and succeed)
    ct:pal("submitting 8"),
    Txn8 = mvars(#{garbage_value => but_what_now}, 7, [Priv2, Priv3, Priv6]),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn8]) || M <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, but_what_now),

    %% try with only two keys (and fail)
    Txn9 = mvars(#{garbage_value => sheep_jokes}, 8, [Priv3, Priv6]),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn9]) || M <- Miners],

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn9]) || Miner <- Miners],

    false = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, sheep_jokes, 10),

    %% try with two valid and one corrupted key proof (and fail again)
    Txn10_0 = blockchain_txn_vars_v1:new(#{garbage_value => cmon}, 8),
    Proofs10_0 = [blockchain_txn_vars_v1:create_proof(P, Txn10_0)
                || P <- [Priv2, Priv3, Priv4]],
    [Proof10 | Rem] = Proofs10_0,
    Proof10Corrupted = <<Proof10/binary, "asdasdasdas">>,
    Txn10 = blockchain_txn_vars_v1:multi_proofs(Txn10_0, [Proof10Corrupted | Rem]),

    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn10]) || M <- Miners],

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn9]) || Miner <- Miners],

    false = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, cmon, 10),

    %% make sure that we safely ignore bad proofs and keys
    #{secret := Priv8, public := _Pub8} = libp2p_crypto:generate_keys(ecc_compact),

    Txn11a = mvars(#{garbage_value => sheep_are_inherently_unfunny}, 8,
                   [Priv2, Priv3, Priv4, Priv5, Priv6, Priv8]),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn11a]) || M <- Miners],
    false = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, sheep_are_inherently_unfunny, 10),

    Txn11b = mvars(#{garbage_value => sheep_are_inherently_unfunny}, 8,
                   [Priv2, Priv3, Priv5, Priv6, Priv8]),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn11b]) || M <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, sheep_are_inherently_unfunny),

    Txn12_0 = blockchain_txn_vars_v1:new(
                #{garbage_value => so_true}, 9,
                #{multi_keys => [BinPub3, BinPub4, BinPub5, BinPub6, BinPub7]}),
    Proofs12 = [blockchain_txn_vars_v1:create_proof(P, Txn12_0)
                %% shuffle the proofs to make sure we no longer need
                %% them in the correct order
                || P <- miner_ct_utils:shuffle([Priv7])],
    Txn12_1 = blockchain_txn_vars_v1:multi_key_proofs(Txn12_0, Proofs12),
    Proofs = [blockchain_txn_vars_v1:create_proof(P, Txn12_1)
               || P <- [Priv3, Priv4, Priv5]],
    Txn12 = blockchain_txn_vars_v1:multi_proofs(Txn12_1, Proofs),

    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn12]) || M <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, so_true),

    Txn13 = mvars(#{garbage_value => lets_all_hate_on_sheep}, 10,
                  [Priv5, Priv6, Priv7]),
    _ = [ok = ct_rpc:call(M, blockchain_worker, submit_txn, [Txn13]) || M <- Miners],
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, lets_all_hate_on_sheep),

    ok.

mvars(Map, Nonce, Privs) ->
    Txn0 = blockchain_txn_vars_v1:new(Map, Nonce),
    Proofs = [blockchain_txn_vars_v1:create_proof(P, Txn0)
               || P <- Privs],
    blockchain_txn_vars_v1:multi_proofs(Txn0, Proofs).

vars(Map, Nonce, Priv) ->
    Txn0 = blockchain_txn_vars_v1:new(Map, Nonce),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn0),
    blockchain_txn_vars_v1:proof(Txn0, Proof).

version_change_test(Config) ->
    %% get all the miners
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),


    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),

    %% baseline: old-style chain vars are working

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{garbage_value => totes_goats_garb},
    Proof = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars),
    Txn1_0 = blockchain_txn_vars_v1:new(Vars, 2),
    Txn1_1 = blockchain_txn_vars_v1:proof(Txn1_0, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1_1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, totes_goats_garb),

    %% switch chain version

    Vars2 = #{?chain_vars_version => 2},
    Proof2 = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars2),
    Txn2_0 = blockchain_txn_vars_v1:new(Vars2, 3),
    Txn2_1 = blockchain_txn_vars_v1:proof(Txn2_0, Proof2),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn2_1])
         || Miner <- Miners],

    %% make sure that it has taken effect
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?chain_vars_version, 2),

    %% try a new-style txn change

    Vars3 = #{garbage_value => goats_are_not_garb},
    Txn3_0 = blockchain_txn_vars_v1:new(Vars3, 4),
    Proof3 = blockchain_txn_vars_v1:create_proof(Priv, Txn3_0),
    Txn3_1 = blockchain_txn_vars_v1:proof(Txn3_0, Proof3),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn3_1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    %% make sure old style is now closed off.

    Vars4 = #{garbage_value => goats_are_too_garb},
    Txn4_0 = blockchain_txn_vars_v1:new(Vars4, 5),
    Proof4 = blockchain_txn_vars_v1:legacy_create_proof(Priv, Vars4),
    Txn4_1 = blockchain_txn_vars_v1:proof(Txn4_0, Proof4),

    {ok, Start4} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn4_1])
         || Miner <- Miners],

    %% wait until height has increased by 15
    ok = miner_ct_utils:wait_for_gte(height, Miners, Start4 + 15),
    %% and then confirm the transaction took hold
    ok = miner_ct_utils:wait_for_chain_var_update(Miners, garbage_value, goats_are_not_garb),

    ok.


election_v3_test(Config) ->
    %% get all the miners
    Miners = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 2),

    Blockchain1 = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {Priv, _Pub} = ?config(master_key, Config),

    Vars = #{?election_version => 3,
             ?election_bba_penalty => 0.01,
             ?election_seen_penalty => 0.05},

    Txn = blockchain_txn_vars_v1:new(Vars, 2),
    Proof = blockchain_txn_vars_v1:create_proof(Priv, Txn),
    Txn1 = blockchain_txn_vars_v1:proof(Txn, Proof),

    _ = [ok = ct_rpc:call(Miner, blockchain_worker, submit_txn, [Txn1])
         || Miner <- Miners],

    ok = miner_ct_utils:wait_for_chain_var_update(Miners, ?election_version, 3),

    {ok, Start} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),

    %% wait until height has increased by 10
    ok = miner_ct_utils:wait_for_gte(height, Miners, Start + 10),

    %% get all blocks and check that they have the appropriate
    %% metadata

    [begin
         PrevBlock = miner_ct_utils:get_block(N - 1, hd(Miners)),
         Block = miner_ct_utils:get_block(N, hd(Miners)),
         ct:pal("n ~p s ~p b ~p", [N, Start, Block]),
         case N of
             _ when N < Start ->
                 ?assertEqual([], blockchain_block_v1:seen_votes(Block)),
                 ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block));
             %% skip these because we're not 100% certain when the var
             %% will become effective.
             _ when N < Start + 5 ->
                 ok;
             _ ->
                 Ts = blockchain_block:transactions(PrevBlock),
                 case lists:filter(fun(T) ->
                                           blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                                   end, Ts) of
                     [] ->
                         ?assertNotEqual([], blockchain_block_v1:seen_votes(Block)),
                         ?assertNotEqual(<<>>, blockchain_block_v1:bba_completion(Block));
                     %% first post-election block has no info
                     _ ->
                         ?assertEqual([<<>>], lists:usort([X || {_, X} <- blockchain_block_v1:seen_votes(Block)])),
                         ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block))
                 end
         end
     end
     || N <- lists:seq(2, Start + 10)],

    %% two should guarantee at least one consensus member is down but
    %% that block production is still happening
    StopList = lists:sublist(Miners, 7, 2),
    ct:pal("stop list ~p", [StopList]),
    _Stop = miner_ct_utils:stop_miners(StopList),

    {ok, Start2} = ct_rpc:call(hd(Miners), blockchain, height, [Blockchain1]),
    %% try a skip to move past the occasional stuck group
    [ct_rpc:call(M, miner, hbbft_skip, []) || M <- lists:sublist(Miners, 1, 6)],

    ok = miner_ct_utils:wait_for_gte(height, lists:sublist(Miners, 1, 6), Start2 + 10, all, 120),

    [begin
         PrevBlock = miner_ct_utils:get_block(N - 1, hd(Miners)),
         Block = miner_ct_utils:get_block(N, hd(Miners)),
         ct:pal("n ~p s ~p b ~p", [N, Start, Block]),
         Ts = blockchain_block:transactions(PrevBlock),
         case lists:filter(fun(T) ->
                                   blockchain_txn:type(T) == blockchain_txn_consensus_group_v1
                           end, Ts) of
             [] ->
                 Seen = blockchain_block_v1:seen_votes(Block),
                 %% given the current code, BBA will always be 2f+1,
                 %% so there's no point in checking it other than
                 %% seeing that it is not <<>> or <<0>>
                 %% when we have something to check, this might be
                 %% helpful: lists:sum([case $; band (1 bsl N) of 0 -> 0; _ -> 1 end || N <- lists:seq(1, 7)]).
                 BBA = blockchain_block_v1:bba_completion(Block),

                 ?assertNotEqual([], Seen),
                 ?assertNotEqual(<<>>, BBA),
                 ?assertNotEqual(<<0>>, BBA),

                 Len = length(Seen),
                 ?assert(Len == 6 orelse Len == 5),

                 Votes = lists:usort([Vote || {_ID, Vote} <- Seen]),
                 [?assertNotEqual(<<127>>, V) || V <- Votes];
             %% first post-election block has no info
             _ ->
                 Seen = blockchain_block_v1:seen_votes(Block),
                 Votes = lists:usort([Vote || {_ID, Vote} <- Seen]),
                 ?assertEqual([<<>>], Votes),
                 ?assertEqual(<<>>, blockchain_block_v1:bba_completion(Block))
         end
     end
     %% start at +2 so we don't get a stale block that saw the
     %% stopping nodes.
     || N <- lists:seq(Start2 + 2, Start2 + 10)],

    ok.

snapshot_test(Config) ->
    %% get all the miners
    Miners0 = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    [Target | Miners] = Miners0,

    ct:pal("target ~p", [Target]),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 7),
    [{Target, TargetEnv}] = miner_ct_utils:stop_miners([Target]),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 15),
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {SnapshotBlockHeight, SnapshotBlockHash, SnapshotHash} =
        ct_rpc:call(hd(Miners), blockchain, find_last_snapshot, [Chain]),
    ?assert(is_binary(SnapshotHash)),
    ?assert(is_binary(SnapshotBlockHash)),
    ?assert(is_integer(SnapshotBlockHeight)),
    ct:pal("Snapshot hash is ~p at height ~p~n in block ~p",
           [SnapshotHash, SnapshotBlockHeight, SnapshotBlockHash]),

    BlockchainEnv = proplists:get_value(blockchain, TargetEnv),
    NewBlockchainEnv = [{blessed_snapshot_block_hash, SnapshotHash}, {blessed_snapshot_block_height, SnapshotBlockHeight},
                        {quick_sync_mode, blessed_snapshot}, {honor_quick_sync, true}|BlockchainEnv],
    NewTargetEnv = lists:keyreplace(blockchain, 1, TargetEnv, {blockchain, NewBlockchainEnv}),

    ct:pal("new blockchain env ~p", [NewTargetEnv]),

    miner_ct_utils:start_miners([{Target, NewTargetEnv}]),

    miner_ct_utils:wait_until(
      fun() ->
              try
                  undefined =/= ct_rpc:call(Target, blockchain_worker, blockchain, [])
              catch _:_ ->
                       false
              end
      end, 50, 200),

    ok = ct_rpc:call(Target, blockchain, reset_ledger_to_snap, []),


    ok = miner_ct_utils:wait_for_gte(height, Miners0, 25, all, 20),
    ok.


high_snapshot_test(Config) ->
    %% get all the miners
    Miners0 = ?config(miners, Config),
    ConsensusMiners = ?config(consensus_miners, Config),

    [Target | Miners] = Miners0,

    ct:pal("target ~p", [Target]),

    ?assertNotEqual([], ConsensusMiners),
    ?assertEqual(7, length(ConsensusMiners)),

    %% make sure that elections are rolling
    ok = miner_ct_utils:wait_for_gte(epoch, Miners, 1),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 7),
    [{Target, TargetEnv}] = miner_ct_utils:stop_miners([Target]),
    ok = miner_ct_utils:wait_for_gte(height, Miners, 70, all, 600),
    Chain = ct_rpc:call(hd(Miners), blockchain_worker, blockchain, []),
    {SnapshotBlockHeight, SnapshotBlockHash, SnapshotHash} =
        ct_rpc:call(hd(Miners), blockchain, find_last_snapshot, [Chain]),
    ?assert(is_binary(SnapshotHash)),
    ?assert(is_binary(SnapshotBlockHash)),
    ?assert(is_integer(SnapshotBlockHeight)),
    ct:pal("Snapshot hash is ~p at height ~p~n in block ~p",
           [SnapshotHash, SnapshotBlockHeight, SnapshotBlockHash]),

    %% TODO: probably at this step we should delete all the blocks
    %% that the downed node has

    BlockchainEnv = proplists:get_value(blockchain, TargetEnv),
    NewBlockchainEnv = [{blessed_snapshot_block_hash, SnapshotHash}, {blessed_snapshot_block_height, SnapshotBlockHeight},
                        {quick_sync_mode, blessed_snapshot}, {honor_quick_sync, true}|BlockchainEnv],
    NewTargetEnv = lists:keyreplace(blockchain, 1, TargetEnv, {blockchain, NewBlockchainEnv}),

    ct:pal("new blockchain env ~p", [NewTargetEnv]),

    miner_ct_utils:start_miners([{Target, NewTargetEnv}]),

    timer:sleep(5000),
    ok = ct_rpc:call(Target, blockchain, reset_ledger_to_snap, []),

    ok = miner_ct_utils:wait_for_gte(height, Miners0, 80, all, 30),
    ok.




%% ------------------------------------------------------------------
%% Local Helper functions
%% ------------------------------------------------------------------







