defmodule NervesHubWWWWeb.DeviceLiveConsoleTest do
  use NervesHubWWWWeb.ConnCase.Browser, async: false

  import Phoenix.ChannelTest

  alias NervesHubWWWWeb.Router.Helpers, as: Routes
  alias NervesHubWWWWeb.{DeviceLive.Console, Endpoint}
  alias NervesHubDevice.Presence

  alias Phoenix.Socket.Broadcast

  setup %{fixture: %{org: org, device: device, product: product}} = context do
    Endpoint.subscribe("console:#{device.id}")

    # TODO: Use Plug.Conn.get_session/1 when upgraded to Plug >= 1.8
    session =
      context.conn.private.plug_session
      |> Enum.into(%{}, fn {k, v} -> {String.to_atom(k), v} end)
      |> Map.put(:org_id, org.id)
      |> Map.put(:product_id, product.id)
      |> Map.put(:device_id, device.id)

    unless context[:skip_presence] do
      Presence.track(self(), "product:#{product.id}:devices", device.id, %{
        console_available: true
      })
    end

    [session: session]
  end

  describe "mount" do
    test "successful mount init IEx server on device", %{session: session} do
      {:ok, _view, _html} = mount(Endpoint, Console, session: session)
      assert_broadcast("init", %{})
    end

    @tag skip_presence: true
    test "redirects when device not configured for remote IEx", %{
      fixture: %{org: org, product: product, device: device},
      session: session
    } do
      {:error, %{redirect: somewhere}} = mount(Endpoint, Console, session: session)
      refute_broadcast("init", %{})
      path = Routes.device_path(Endpoint, :show, org.name, product.name, device.identifier)
      assert somewhere == path
    end

    test "redirects on mount with unrecognized session structure" do
      home_path = Routes.home_path(Endpoint, :index)

      assert {:error, %{redirect: ^home_path}} =
               mount(Endpoint, Console, session: "wat?! who der?!")
    end
  end

  describe "handle_event" do
    test "iex_submit", %{user: user, session: session} do
      {:ok, view, _html} = mount(Endpoint, Console, session: session)
      input = "Howdy"
      iex_line = "iex(#{user.username})&gt; #{input}"

      assert render_submit(view, :iex_submit, %{iex_input: input}) =~ iex_line

      assert_broadcast("add_line", %{data: iex_line})
      assert_broadcast("io_reply", %{data: input, kind: "get_line"})
    end

    test "iex_submit - clear text", %{session: session} do
      {:ok, view, _html} = mount(Endpoint, Console, session: session)

      refute render_submit(view, :iex_submit, %{iex_input: "clear"}) =~ "NervesHub IEx Live"
    end
  end

  describe "handle_info" do
    test "put_chars", %{session: session} do
      {:ok, view, html} = mount(Endpoint, Console, session: session)

      refute html =~ "Howdy"

      msg = %Broadcast{event: "put_chars", payload: %{"data" => "Howdy"}}
      send(view.pid, msg)

      assert render(view) =~ "Howdy"
    end

    test "put_chars with binary list", %{session: session} do
      list_line = [72, 111, 119, 100, 121, 32, 'Partner']

      {:ok, view, html} = mount(Endpoint, Console, session: session)

      refute html =~ "Howdy Partner"

      msg = %Broadcast{event: "put_chars", payload: %{"data" => list_line}}
      send(view.pid, msg)

      assert render(view) =~ "Howdy Partner"
    end

    test "get_line", %{user: user, session: session} do
      {:ok, view, html} = mount(Endpoint, Console, session: session)

      refute html =~ "Howdy"

      msg = %Broadcast{event: "get_line", payload: %{"data" => "iex(1)>"}}
      send(view.pid, msg)

      assert render(view) =~ "iex(#{user.username})&gt;"
    end

    test "add_line", %{session: session} do
      {:ok, view, html} = mount(Endpoint, Console, session: session)

      refute html =~ "Howdy"

      msg = %Broadcast{event: "add_line", payload: %{data: "wat it do?"}}
      send(view.pid, msg)

      assert render(view) =~ "wat it do?"
    end
  end
end
