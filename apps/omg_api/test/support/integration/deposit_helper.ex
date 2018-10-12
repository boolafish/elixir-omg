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

defmodule OMG.API.Integration.DepositHelper do
  @moduledoc """
  Common helper functions that are useful when integration-testing the child chain and watcher requiring deposits
  """

  alias OMG.API.Crypto
  alias OMG.Eth

  @eth Crypto.zero_address()

  def deposit_to_child_chain(to, value, token \\ @eth)

  def deposit_to_child_chain(to, value, @eth) do
    {:ok, %{"blockNumber" => deposit_eth_height} = receipt} =
      Eth.RootChain.deposit(value, to) |> Eth.DevHelpers.transact_sync!()

    deposit_blknum = Eth.RootChain.deposit_blknum_from_receipt(receipt)

    deposit_eth_height
    |> decode_eth_height()
    |> wait_deposit_recognized()

    deposit_blknum
  end

  def deposit_to_child_chain(to, value, token_addr) when is_binary(token_addr) and byte_size(token_addr) == 20 do
    contract_addr = Eth.Encoding.from_hex(Application.fetch_env!(:omg_eth, :contract_addr))

    to |> Eth.Token.mint(value, token_addr) |> Eth.DevHelpers.transact_sync!()
    to |> Eth.Token.approve(contract_addr, value, token_addr) |> Eth.DevHelpers.transact_sync!()

    {:ok, %{"blockNumber" => deposit_eth_height} = receipt} =
      to |> Eth.RootChain.deposit_token(token_addr, value) |> Eth.DevHelpers.transact_sync!()

    token_deposit_blknum = Eth.RootChain.deposit_blknum_from_receipt(receipt)

    deposit_eth_height
    |> decode_eth_height()
    |> wait_deposit_recognized()

    token_deposit_blknum
  end

  defp wait_deposit_recognized(deposit_eth_height) do
    wait_ethereum_event_block_finality_margin(deposit_eth_height)

    # sleeping some more, until the deposit is spendable
    geth_mining_period_ms = 1000
    Process.sleep(geth_mining_period_ms + Application.get_env(:omg_api, :ethereum_event_check_height_interval_ms) * 3)

    :ok
  end

  defp decode_eth_height("0x" <> eth_height_hex) do
    {eth_height, ""} = Integer.parse(eth_height_hex, 16)
    eth_height
  end

  defp wait_ethereum_event_block_finality_margin(eth_height) do
    post_event_block_finality = eth_height + Application.get_env(:omg_api, :ethereum_event_block_finality_margin)

    {:ok, _} = wait_for_root_chain_block(post_event_block_finality)

    # sleeping until the deposit is spendable
    geth_mining_period_ms = 1000
    Process.sleep(geth_mining_period_ms + Application.get_env(:omg_api, :ethereum_event_check_height_interval_ms) * 3)

    :ok
  end

  defp wait_for_root_chain_block(awaited_eth_height, timeout \\ 60_000) do
    f = fn ->
      {:ok, eth_height} = OMG.Eth.get_ethereum_height()

      if eth_height < awaited_eth_height, do: :repeat, else: {:ok, eth_height}
    end

    fn -> Eth.WaitFor.repeat_until_ok(f) end |> Task.async() |> Task.await(timeout)
  end
end
