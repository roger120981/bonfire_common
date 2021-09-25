defmodule Bonfire.Web.Plugs.GuestOnly do

  use Bonfire.Web, :plug

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_account],
      do: not_permitted(conn),
      else: conn
  end

  defp not_permitted(conn) do
    conn
    |> put_flash(:error, "That page is only accessible to guests.")
    |> redirect(to: path(:home))
    |> halt()
  end

end
