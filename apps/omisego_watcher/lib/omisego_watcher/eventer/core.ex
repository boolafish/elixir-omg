defmodule OmiseGOWatcher.Eventer.Core do
  @moduledoc """
  Functional core of eventer
  """

  alias OmiseGO.API.State.Transaction
  alias OmiseGOWatcher.Eventer.Event

  @address_topic "address"

  @spec notify(any()) :: list({Event.t(), binary()})
  def notify(event_triggers) do
    Enum.flat_map(event_triggers, &get_events_with_topic(&1))
  end

  defp get_events_with_topic(event_trigger) do
    address_received_events = get_address_received_events(event_trigger)
    address_spent_events = get_address_spent_events(event_trigger)
    address_received_events ++ address_spent_events
  end


  defp get_address_spent_events(
         %{
           tx: %Transaction.Recovered{
             raw_tx: %Transaction{},
             spender1: spender1,
             spender2: spender2
           }
         } = event_trigger
       ) do

    [spender1, spender2]
    |> Enum.filter(&Transaction.account_address?/1)
    |> Enum.map(&(create_address_spent_event(signed, &1)))
    |> Enum.uniq()
  end

  defp create_address_spent_event(event_trigger, address) do
    subtopic = create_address_subtopic(address)
    {subtopic, Event.AddressSpent.name(), struct(Event.AddressSpent, event_trigger)}
  end


  defp get_address_received_events(
         %{
           tx: %Transaction.Recovered{
             raw_tx: %Transaction{
               newowner1: newowner1,
               newowner2: newowner2
             }
           }
         } = event_trigger
       ) do
    [newowner1, newowner2]
    |> Enum.filter(&Transaction.account_address?/1)
    |> Enum.map(&create_address_received_event(event_trigger, &1))
    |> Enum.uniq()
  end

  defp create_address_received_event(event_trigger, address) do
    subtopic = create_address_subtopic(address)

    {subtopic, Event.AddressReceived.name(), struct(Event.AddressReceived, event_trigger)}
  end

  defp create_address_subtopic(address) do
    encoded_address = "0x" <> Base.encode16(address, case: :lower)
    create_subtopic(@address_topic, encoded_address)
  end

  defp create_subtopic(main_topic, subtopic), do: main_topic <> ":" <> subtopic

end
