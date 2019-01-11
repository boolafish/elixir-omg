# Copyright 2018 OmiseGO Pte Ltd
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OMG.Watcher.ExitProcessor.Core do
  @moduledoc """
  The functional, zero-side-effect part of the exit processor. Logic should go here:
    - orchestrating the persistence of the state
    - finding invalid exits, disseminating them as events according to rules
    - MoreVP protocol managing should go here
  """

  alias OMG.API.Crypto
  alias OMG.API.State.Transaction
  alias OMG.API.Utxo
  require Utxo
  alias OMG.Watcher.Challenger.Tools
  alias OMG.Watcher.Event
  alias OMG.Watcher.ExitProcessor.CompetitorInfo
  alias OMG.Watcher.ExitProcessor.ExitInfo
  alias OMG.Watcher.ExitProcessor.InFlightExitInfo
  alias OMG.Watcher.ExitProcessor.TxAppendix

  @default_sla_margin 10
  @zero_address Crypto.zero_address()

  @type tx_hash() :: <<_::32>>
  @type output_offset() :: 0..7

  defstruct [:sla_margin, exits: %{}, in_flight_exits: %{}, competitors: %{}]

  @type t :: %__MODULE__{
          sla_margin: non_neg_integer(),
          exits: %{Utxo.Position.t() => ExitInfo.t()},
          in_flight_exits: %{tx_hash() => InFlightExitInfo.t()},
          competitors: %{tx_hash() => CompetitorInfo.t()}
        }

  @type competitor_data_t :: %{
          inflight_txbytes: binary(),
          inflight_input_index: non_neg_integer(),
          competing_txbytes: binary(),
          competing_input_index: non_neg_integer(),
          competing_sig: binary(),
          competing_txid: nil,
          competing_proof: nil
        }

  @doc """
  Reads database-specific list of exits and turns them into current state
  """
  @spec init(
          db_exits :: [{{pos_integer, non_neg_integer, non_neg_integer}, map}],
          db_in_flight_exits :: [{tx_hash(), InFlightExitInfo.t()}],
          db_competitors :: [{tx_hash(), CompetitorInfo.t()}],
          sla_margin :: non_neg_integer
        ) :: {:ok, t()}
  def init(db_exits, db_in_flight_exits, db_competitors, sla_margin \\ @default_sla_margin) do
    {:ok,
     %__MODULE__{
       exits:
         db_exits
         |> Enum.map(fn {{blknum, txindex, oindex}, v} ->
           {Utxo.position(blknum, txindex, oindex), struct(ExitInfo, v)}
         end)
         |> Map.new(),
       in_flight_exits: db_in_flight_exits |> Map.new(),
       competitors: db_competitors |> Map.new(),
       sla_margin: sla_margin
     }}
  end

  @doc """
  Add new exits from Ethereum events into tracked state.

  The list of `exit_contract_statuses` is used to track current (as in wall-clock "now", not syncing "now") status.
  This is to prevent spurious invalid exit events being fired during syncing for exits that were challenged/finalized
  Still we do want to track these exits when syncing, to have them spend from `OMG.API.State` on their finalization
  """
  @spec new_exits(t(), list(map()), list(map)) :: {t(), list()} | {:error, :unexpected_events}
  def new_exits(state, new_exits, exit_contract_statuses)

  def new_exits(_, new_exits, exit_contract_statuses) when length(new_exits) != length(exit_contract_statuses) do
    {:error, :unexpected_events}
  end

  def new_exits(%__MODULE__{exits: exits} = state, new_exits, exit_contract_statuses) do
    new_exits_kv_pairs =
      new_exits
      |> Enum.zip(exit_contract_statuses)
      |> Enum.map(fn {%{utxo_pos: utxo_pos} = exit_info, contract_status} ->
        is_active = parse_contract_exit_status(contract_status)
        map_exit_info = exit_info |> Map.delete(:utxo_pos) |> Map.put(:is_active, is_active)
        {Utxo.Position.decode(utxo_pos), struct(ExitInfo, map_exit_info)}
      end)

    db_updates =
      new_exits_kv_pairs
      |> Enum.map(&ExitInfo.make_db_update/1)

    new_exits_map = Map.new(new_exits_kv_pairs)

    {%{state | exits: Map.merge(exits, new_exits_map)}, db_updates}
  end

  defp parse_contract_exit_status({@zero_address, _contract_token, _contract_amount}), do: false
  defp parse_contract_exit_status({_contract_owner, _contract_token, _contract_amount}), do: true

  # TODO: syncing problem (look new exits)
  @doc """
   Add new in flight exits from Ethereum events into tracked state.
  """
  @spec new_in_flight_exits(t(), list(map()), list(map())) :: {t(), list()} | {:error, :unexpected_events}
  def new_in_flight_exits(state, new_ifes_events, contract_statuses)

  def new_in_flight_exits(_state, new_ifes_events, contract_statuses)
      when length(new_ifes_events) != length(contract_statuses),
      do: {:error, :unexpected_events}

  def new_in_flight_exits(%__MODULE__{in_flight_exits: ifes} = state, new_ifes_events, contract_statuses) do
    new_ifes_kv_pairs =
      new_ifes_events
      |> Enum.zip(contract_statuses)
      |> Enum.map(fn {%{tx_bytes: tx_bytes, signatures: signatures}, {timestamp, contract_ife_id} = contract_status} ->
        is_active = parse_contract_in_flight_exit_status(contract_status)
        InFlightExitInfo.new(tx_bytes, signatures, contract_ife_id, timestamp, is_active)
      end)

    db_updates =
      new_ifes_kv_pairs
      |> Enum.map(&InFlightExitInfo.make_db_update/1)

    new_ifes = new_ifes_kv_pairs |> Map.new()

    {%{state | in_flight_exits: Map.merge(ifes, new_ifes)}, db_updates}
  end

  defp parse_contract_in_flight_exit_status({timestamp, _contract_id}), do: timestamp != 0

  @doc """
    Add piggybacks from Ethereum events into tracked state.
  """
  @spec new_piggybacks(t(), [{tx_hash(), output_offset()}]) :: {t(), list()}
  def new_piggybacks(%__MODULE__{in_flight_exits: ifes} = state, piggybacks) do
    ifes_to_update =
      piggybacks
      |> Enum.map(fn %{tx_hash: tx_hash} -> tx_hash end)
      |> (&Map.take(ifes, &1)).()
      # initialises all ifes as not updated
      |> Enum.map(fn {key, value} -> {key, {value, false}} end)
      |> Map.new()

    updated_ifes =
      piggybacks
      |> Enum.reduce(ifes_to_update, fn %{tx_hash: tx_hash, output_index: index}, acc ->
        with {:ok, {ife, _}} <- Map.fetch(acc, tx_hash),
             {:ok, updated} <- InFlightExitInfo.piggyback(ife, index) do
          # sets updated ife and flags it as changed
          %{acc | tx_hash => {updated, true}}
        else
          # if impossible to piggyback - do nothing
          _ ->
            acc
        end
      end)
      |> Enum.reduce([], fn
        {tx_hash, {ife, true}}, acc -> [{tx_hash, ife} | acc]
        {_, {_, false}}, acc -> acc
      end)
      |> Map.new()

    db_updates = Enum.map(updated_ifes, &InFlightExitInfo.make_db_update/1)

    {%{state | in_flight_exits: Map.merge(state.in_flight_exits, updated_ifes)}, db_updates}
  end

  @doc """
  Finalize exits based on Ethereum events, removing from tracked state if valid.

  Invalid finalizing exits should continue being tracked as `is_active`, to continue emitting events.
  This includes non-`is_active` exits that finalize invalid, which are turned to be `is_active` now.
  """
  @spec finalize_exits(t(), validities :: {list(Utxo.Position.t()), list(Utxo.Position.t())}) :: {t(), list()}
  def finalize_exits(%__MODULE__{exits: exits} = state, {valid_finalizations, invalid}) do
    # handling valid finalizations
    state = %{state | exits: Map.drop(exits, valid_finalizations)}
    db_updates = delete_positions(valid_finalizations)

    {state, activating_db_updates} = activate_on_invalid_finalization(state, invalid)

    {state, db_updates ++ activating_db_updates}
  end

  defp activate_on_invalid_finalization(%__MODULE__{exits: exits} = state, invalid_finalizations) do
    exits_to_activate =
      exits
      |> Map.take(invalid_finalizations)
      |> Enum.map(fn {k, v} -> {k, Map.update!(v, :is_active, fn _ -> true end)} end)
      |> Map.new()

    activating_db_updates =
      exits_to_activate
      |> Enum.map(&ExitInfo.make_db_update/1)

    state = %{state | exits: Map.merge(exits, exits_to_activate)}
    {state, activating_db_updates}
  end

  @spec challenge_exits(t(), list(map)) :: {t(), list}
  def challenge_exits(%__MODULE__{exits: exits} = state, challenges) do
    challenged_positions = get_positions_from_events(challenges)
    state = %{state | exits: Map.drop(exits, challenged_positions)}
    db_updates = delete_positions(challenged_positions)
    {state, db_updates}
  end

  defp get_positions_from_events(exits) do
    exits
    |> Enum.map(fn %{utxo_pos: utxo_pos} = _finalization_info -> Utxo.Position.decode(utxo_pos) end)
  end

  defp delete_positions(utxo_positions) do
    utxo_positions
    |> Enum.map(fn Utxo.position(blknum, txindex, oindex) -> {:delete, :exit_info, {blknum, txindex, oindex}} end)
  end

  # TODO: better name? `new_ife_challenges`? this is just registering an event on eth, so "challenge" verb misleads
  #       would probably require changing a few of these names to the `new_something` convention
  @spec challenge_in_flight_exits(t(), [map()]) :: {t(), list()}
  def challenge_in_flight_exits(%__MODULE__{in_flight_exits: ifes, competitors: competitors} = state, challenges_events) do
    challenges =
      challenges_events
      |> Enum.map(fn %{
                       call_data: %{
                         competing_tx: competing_tx_bytes,
                         competing_tx_input_index: competing_input_index,
                         competing_tx_sig: signature
                       }
                     } ->
        CompetitorInfo.new(competing_tx_bytes, competing_input_index, signature)
      end)

    new_competitors = challenges |> Map.new()
    competitors_db_updates = challenges |> Enum.map(&CompetitorInfo.make_db_update/1)

    updated_ifes =
      challenges_events
      |> Enum.map(fn %{tx_hash: tx_hash, competitor_position: position} ->
        updated_ife = ifes |> Map.fetch!(tx_hash) |> InFlightExitInfo.challenge(position)
        {tx_hash, updated_ife}
      end)

    ife_db_updates = updated_ifes |> Enum.map(&InFlightExitInfo.make_db_update/1)

    state = %{
      state
      | competitors: Map.merge(competitors, new_competitors),
        in_flight_exits: Map.merge(ifes, Map.new(updated_ifes))
    }

    {state, competitors_db_updates ++ ife_db_updates}
  end

  @spec respond_to_in_flight_exits_challenges(t(), [map()]) :: {t(), list()}
  def respond_to_in_flight_exits_challenges(%__MODULE__{in_flight_exits: _ifes} = state, _responds_events) do
    # TODO: implement and test (in InFlightExitInfo callback is already written)
    {state, []}
  end

  @spec challenge_piggybacks(t(), [map()]) :: {t(), list()}
  def challenge_piggybacks(%__MODULE__{in_flight_exits: ifes} = state, challenges) do
    ifes_to_update =
      challenges
      |> Enum.map(fn %{tx_hash: tx_hash} -> tx_hash end)
      |> (&Map.take(ifes, &1)).()
      # initialises all ifes as not updated
      |> Enum.map(fn {key, value} -> {key, {value, false}} end)
      |> Map.new()

    updated_ifes =
      challenges
      |> Enum.reduce(ifes_to_update, fn %{tx_hash: tx_hash, output_index: output_id}, acc ->
        with {:ok, {ife, _}} <- Map.fetch(acc, tx_hash),
             {:ok, updated_ife} <- InFlightExitInfo.challenge_piggyback(ife, output_id) do
          # mark as updated
          %{acc | tx_hash => {updated_ife, true}}
        else
          _ -> acc
        end
      end)
      |> Enum.reduce([], fn
        {tx_hash, {ife, true}}, acc -> [{tx_hash, ife} | acc]
        _, acc -> acc
      end)
      |> Map.new()

    db_updates = updated_ifes |> Enum.map(&InFlightExitInfo.make_db_update/1)

    {%{state | in_flight_exits: Map.merge(ifes, updated_ifes)}, db_updates}
  end

  # TODO: write tests
  @spec finalize_in_flight_exits(t(), [map()]) :: {t(), list()}
  def finalize_in_flight_exits(%__MODULE__{in_flight_exits: ifes} = state, finalizations) do
    ifes_to_update =
      finalizations
      |> Enum.reduce(%{}, fn %{in_flight_exit_id: id}, acc ->
        with :not_found <-
               Enum.find(ifes, :not_found, fn {_tx_hash, %InFlightExitInfo{contract_id: contract_id}} ->
                 id == contract_id
               end) do
          acc
        else
          # map by id from contract and mark as not updated
          {tx_hash, ife} ->
            %{acc | id => {tx_hash, ife, false}}
        end
      end)

    updated_ifes =
      finalizations
      |> Enum.reduce(ifes_to_update, fn %{in_flight_exit_id: id, output_id: output}, acc ->
        with {:ok, {tx_hash, ife, _}} <- Enum.fetch(acc, id),
             {:ok, updated_ife} <- InFlightExitInfo.finalize(ife, output) do
          # update value and flag as updated
          %{acc | id => {tx_hash, updated_ife, true}}
        else
          _ -> acc
        end
      end)
      |> Enum.reduce([], fn
        {_, {tx_hash, ife, true}}, acc -> [{tx_hash, ife} | acc]
        _, acc -> acc
      end)
      |> Map.new()

    db_updates = updated_ifes |> Enum.map(&InFlightExitInfo.make_db_update/1)

    {%{state | in_flight_exits: Map.merge(ifes, updated_ifes)}, db_updates}
  end

  @doc """
  All the active exits, in-flight exits, exiting output piggybacks etc., based on the current tracked state
  """
  @spec get_exiting_utxo_positions(t()) :: list(Utxo.Position.t())
  def get_exiting_utxo_positions(%__MODULE__{exits: exits, in_flight_exits: ifes} = _state) do
    standard_exits_pos =
      exits
      |> Enum.filter(fn {_key, %ExitInfo{is_active: is_active}} -> is_active end)
      |> Enum.map(fn {utxo_pos, _value} -> utxo_pos end)

    ife_pos =
      ifes
      |> Enum.flat_map(fn {_, ife} -> InFlightExitInfo.get_exiting_utxo_positions(ife) end)

    ife_pos ++ standard_exits_pos
  end

  @doc """
  Based on the result of exit validity (utxo existence), return invalid exits or appropriate notifications

  NOTE: We're using `ExitStarted`-height with `sla_exit_margin` added on top, to determine old, unchallenged invalid
        exits. This is different than documented, according to what we ought to be using
        `exitable_at - sla_exit_margin_s` to determine such exits.

  NOTE: If there were any exits unchallenged for some time in chain history, this might detect breach of SLA,
        even if the exits were eventually challenged (e.g. during syncing)
  """
  @spec invalid_exits(list(boolean), t(), pos_integer, non_neg_integer) ::
          {:ok | {:error, :unchallenged_exit}, list(Event.InvalidExit.t() | Event.UnchallengedExit.t())}
  def invalid_exits(
        utxo_exists_result,
        %__MODULE__{exits: exits, sla_margin: sla_margin} = state,
        eth_height_now,
        blknum_now
      ) do
    exiting_utxo_positions = get_exiting_utxo_positions(state)

    invalid_exit_positions =
      utxo_exists_result
      |> Stream.zip(exiting_utxo_positions)
      |> Stream.filter(fn {utxo_exists, _} -> !utxo_exists end)
      |> Stream.filter(fn {_, Utxo.position(blknum, _, _)} -> blknum < blknum_now end)
      |> Stream.map(fn {_, position} -> position end)

    # get exits which are still invalid and after the SLA margin
    late_invalid_exits =
      exits
      |> Map.take(invalid_exit_positions)
      |> Enum.filter(fn {_, %ExitInfo{eth_height: eth_height}} -> eth_height + sla_margin <= eth_height_now end)

    has_no_late_invalid_exits = Enum.empty?(late_invalid_exits)

    non_late_events =
      invalid_exit_positions
      |> Enum.map(fn position -> ExitInfo.make_event_data(Event.InvalidExit, position, exits[position]) end)

    events =
      late_invalid_exits
      |> Enum.map(fn {position, late_exit} -> ExitInfo.make_event_data(Event.UnchallengedExit, position, late_exit) end)
      |> Enum.concat(non_late_events)

    chain_validity = if has_no_late_invalid_exits, do: :ok, else: {:error, :unchallenged_exit}

    {chain_validity, events}
  end

  @doc """
  Returns a map of requested in flight exits, where keys are IFE hashes and values are IFES
  If given empty list of hashes, all IFEs are returned.
  """
  @spec get_in_flight_exits(__MODULE__.t(), [binary()]) :: %{binary() => InFlightExitInfo.t()}
  def get_in_flight_exits(%__MODULE__{} = state, hashes \\ []), do: in_flight_exits(state, hashes)

  defp in_flight_exits(%__MODULE__{in_flight_exits: ifes}, []), do: ifes

  defp in_flight_exits(%__MODULE__{in_flight_exits: ifes}, hashes), do: Map.take(ifes, hashes)

  @doc """
  Gets the list of open IFEs that have the competitors _somewhere_
  """
  @spec get_ifes_with_competitors(__MODULE__.t()) :: list(binary())
  def get_ifes_with_competitors(state) do
    # TODO: non-canonical ifes from multiple sources will concatenate here
    Stream.concat([with_competitors_from_tx_appendix(state)])
    |> Enum.uniq()
  end

  @doc """
  Gets the root chain conract-required set of data to challenge a non-canonical ife
  """
  @spec get_competitor_for_ife(__MODULE__.t(), list(Crypto.address_t()), binary()) :: competitor_data_t()
  def get_competitor_for_ife(%__MODULE__{in_flight_exits: ifes} = state, input_owners, ife_txbytes) do
    known_txs = get_known_txs(state)

    # get info about the IFE transaction
    {:ok, raw_ife_tx} = Transaction.decode(ife_txbytes)
    %InFlightExitInfo{tx: %Transaction.Signed{} = signed_ife_tx} = ifes[raw_ife_tx |> Transaction.hash()]
    ife_inputs = Transaction.get_inputs(raw_ife_tx) |> Enum.filter(&Utxo.Position.non_zero?/1)

    # find its competitor and get info about that transaction
    # TODO: will not work if there's no competitor here
    known_signed_tx = known_txs |> Enum.find(fn known -> competitor_for(signed_ife_tx, known) end)
    %Transaction.Signed{raw_tx: raw_known_tx} = known_signed_tx
    known_spent_inputs = Transaction.get_inputs(raw_known_tx) |> Enum.filter(&Utxo.Position.non_zero?/1)

    # get info about the double spent input and it's respective indices in transactions
    spent_input = competitor_for(signed_ife_tx, known_signed_tx)
    inflight_input_index = Enum.find_index(ife_inputs, &(&1 == spent_input))
    competing_input_index = Enum.find_index(known_spent_inputs, &(&1 == spent_input))

    owner = Enum.at(input_owners, inflight_input_index)
    {:ok, competing_sig} = Tools.find_sig(known_signed_tx, owner)

    %{
      inflight_txbytes: raw_ife_tx |> Transaction.encode(),
      inflight_input_index: inflight_input_index,
      competing_txbytes: raw_known_tx |> Transaction.encode(),
      competing_input_index: competing_input_index,
      competing_sig: competing_sig,
      competing_txid: nil,
      competing_proof: nil
    }
  end

  defp with_competitors_from_tx_appendix(%__MODULE__{in_flight_exits: ifes} = state) do
    known_txs = get_known_txs(state)

    ifes
    |> Map.values()
    # TODO: not enough - must take oldest competitor into account (?)
    |> Stream.filter(&InFlightExitInfo.is_canonical?/1)
    |> Stream.map(fn %InFlightExitInfo{tx: tx} -> tx end)
    # TODO: expensive!
    |> Stream.filter(fn tx -> known_txs |> Enum.find(&competitor_for(tx, &1)) end)
    |> Stream.map(fn %{raw_tx: raw_tx} -> Transaction.encode(raw_tx) end)
  end

  # tells whether a signle transaction is a competitor for another single transactions, by returning nil or the
  # UTXO position of the input double spent
  defp competitor_for(%Transaction.Signed{raw_tx: raw_tx}, %Transaction.Signed{raw_tx: known_raw_tx}) do
    inputs = Transaction.get_inputs(raw_tx) |> Enum.filter(&Utxo.Position.non_zero?/1)
    known_spent_inputs = Transaction.get_inputs(known_raw_tx) |> Enum.filter(&Utxo.Position.non_zero?/1)

    with true <- Transaction.hash(known_raw_tx) != Transaction.hash(raw_tx),
         Utxo.position(_, _, _) = double_spent_input <- inputs |> Enum.find(&Enum.member?(known_spent_inputs, &1)),
         do: double_spent_input
  end

  defp get_known_txs(%__MODULE__{} = state) do
    TxAppendix.get_all(state)
  end
end
