defmodule Bonfire.Common.Settings do
  use Bonfire.Common.Utils
  use Bonfire.Common.Repo
  # import Bonfire.Me.Integration
  alias Bonfire.Common.Extend
  alias Bonfire.Common.Config

  @doc """
  Get config value for a config key (optionally from a specific OTP app or Bonfire extension)

  These two calls have the same result (i.e. specifying a module as the first key will add the OTP app of that module as the first key):
  `get([:bonfire_me, Bonfire.Me.Users])`
  `get(Bonfire.Me.Users)`

  Same with these two (i.e. not specifying a module or app as the first key will default to the main OTP app):
  `get([:random_atom, :sub_key])`
  `get([:bonfire, :random_atom, :sub_key])`
  """
  def get(key, default \\ nil, opts \\ [])

  def get(keys, default, opts) when is_list(keys) do
    {[otp_app], keys_tree} =
      Config.keys_tree(keys)
      |> Enum.split(1)

    debug(keys_tree, "Get settings in #{inspect(otp_app)} for")

    case get_for_ext(otp_app, to_options(opts)) do
      [] ->
        default

      nil ->
        default

      result ->
        if keys_tree != [] do
          if Keyword.keyword?(result) or is_map(result) do
            get_in(result, keys_tree)
            |> debug(inspect(keys_tree))
            |> maybe_fallback(default)
          else
            error(result, "Settings are in an invalid structure and can't be used")
            default
          end
        else
          maybe_fallback(result, default)
        end
    end
  end

  def get(key, default, opts) do
    get([key], default, opts)
  end

  def get!(key, opts) do
    case get(key, nil, opts) do
      nil ->
        raise "Missing setting or configuration value: #{inspect(key, pretty: true)}"

      value ->
        value
    end
  end

  defp maybe_fallback(nil, fallback), do: fallback
  defp maybe_fallback(val, _fallback), do: val

  defp the_otp_app(module_or_otp_app),
    do: Extend.maybe_extension_loaded!(module_or_otp_app) || Config.top_level_otp_app()

  defp get_for_ext(module_or_otp_app, opts \\ []) do
    if e(opts, :one_scope_only, false) do
      the_otp_app(module_or_otp_app)
      |> fetch_one_scope(opts)
    else
      get_merged_ext(module_or_otp_app, opts)
    end
  end

  @doc """
  Get all config keys/values for a Bonfire extension or OTP app
  """
  defp get_merged_ext(module_or_otp_app, opts \\ []) do
    the_otp_app(module_or_otp_app)
    |> fetch_all_scopes(opts)
    |> deep_merge_reduce()

    # |> debug("domino-merged settings for #{inspect(otp_app)}")
  end

  defp get_merged_ext!(module_or_otp_app, opts \\ []) do
    case get_merged_ext(module_or_otp_app, opts) do
      nil ->
        raise "Missing settings or configuration for extension: #{inspect(module_or_otp_app, pretty: true)}"
        []

      value ->
        value
    end
  end

  # @doc "Fetch all config & settings, both from Mix.Config and DB. Order matters! current_user > current_account > instance > Config"
  defp fetch_all_scopes(otp_app, opts) do
    # debug(opts, "opts")
    current_user = current_user(opts)
    current_user_id = id(current_user)
    current_account = current_account(opts)
    current_account_id = id(current_account)
    scope = e(opts, :scope, nil) || if is_atom(opts), do: opts
    scope_id = id(scope)
    # debug(current_user, "current_user")
    # debug(current_account, "current_account")

    if (scope != :instance and not is_map(current_user) and not is_map(current_account)) or
         (is_struct(current_user) and Map.has_key?(current_user, :settings) and
            not Ecto.assoc_loaded?(current_user.settings)) or
         (is_struct(current_account) and Map.has_key?(current_account, :settings) and
            not Ecto.assoc_loaded?(current_account.settings)) do
      warn(
        otp_app,
        "You should pass a current_user and/or current_account (with settings assoc preloaded) in `opts` depending on what scope of Settings you want for OTP app"
      )

      # debug(opts)
    end

    #  |> debug()
    ([
       Config.get_ext(otp_app)
     ] ++
       [
         if(current_account_id,
           do:
             maybe_fetch(current_account, opts)
             |> settings_data_for_app(otp_app)
         )
       ] ++
       [
         if(current_user_id,
           do:
             maybe_fetch(current_user, opts)
             |> settings_data_for_app(otp_app)
           #  #  |> debug()
           #  #  |> e(:data, otp_app, nil)
           #  |> e(:data, nil)
           #  #  |> debug()
           #  |> e(otp_app, nil)
         )
         #  |> debug()
       ] ++
       if(is_map(scope) and scope_id != current_user_id and scope_id != current_account_id,
         do: [
           maybe_fetch(scope, opts)
           |> settings_data_for_app(otp_app)
         ],
         else: []
       ))
    # |> debug()
    |> filter_empty([])

    # |> debug("list of different configs and settings for #{inspect(otp_app)}")
  end

  defp fetch_one_scope(otp_app, opts) do
    # debug(opts, "opts")
    current_user = current_user(opts)
    current_account = current_account(opts)
    scope = e(opts, :scope, nil)

    cond do
      is_map(scope) ->
        maybe_fetch(scope, opts)
        |> settings_data_for_app(otp_app)

      not is_nil(current_user) ->
        debug("for user")

        maybe_fetch(current_user, opts)
        |> settings_data_for_app(otp_app)

      not is_nil(current_account) ->
        debug("for account")

        maybe_fetch(current_account, opts)
        |> settings_data_for_app(otp_app)

      true ->
        debug("for instance")
        Config.get_ext(otp_app)
    end

    # |> debug("config/settings for #{inspect(otp_app)}")
  end

  defp settings_data(%{json: %{} = data} = settings) when data != %{} do
    prepare_from_json(data)
  end

  defp settings_data(%{data: data}) do
    data
  end

  defp settings_data(_) do
    %{}
  end

  defp settings_data_for_app(settings, otp_app) do
    settings_data(settings)
    |> e(otp_app, nil)

    # IS THIS NEEDED? workaround for case `|> e(:data, otp_app, nil)` messes this up...
    # (settings || %{})
    # |> Map.get(:data, %{})
    # |> Enums.fun(:get, [otp_app, %{}])
    # |> debug("for app #{otp_app}")
  end

  # not including this line in fetch_all_scopes because load_instance_settings preloads it into Config
  # [load_instance_settings() |> e(otp_app, nil) ] # should already be loaded in Config

  def load_instance_settings() do
    maybe_fetch(instance_scope(), preload: true)
    |> settings_data()
  end

  defp maybe_fetch(scope, opts \\ [])

  defp maybe_fetch({_scope, scoped} = _scope_tuple, opts) do
    maybe_fetch(scoped, opts)
  end

  defp maybe_fetch(scope_id, opts) when is_binary(scope_id) do
    if e(opts, :preload, nil) do
      do_fetch(scope_id)
    else
      if !e(opts, :preload, nil) and Config.env() != :test,
        do:
          warn(
            scope_id,
            "cannot lookup Settings since an ID was provided as scope instead of an object with Settings preloaded"
          )

      nil
    end
  end

  defp maybe_fetch(scope, opts) when is_map(scope) do
    case id(scope) do
      nil ->
        # if is_map(scope) or Keyword.keyword?(scope) do
        #   scope
        # else

        error(
          scope,
          "no ID for scope"
        )

        nil

      # end

      scope_id ->
        case scope do
          %{settings: %Ecto.Association.NotLoaded{}} ->
            maybe_fetch(scope_id, opts ++ [recursing: true]) ||
              maybe_warn_not_fetched(scope, opts[:recursing])

          %{settings: settings} ->
            settings

          _ ->
            maybe_fetch(scope_id, opts ++ [recursing: true]) ||
              maybe_warn_not_fetched(scope, opts[:recursing])
        end
    end
  end

  defp maybe_fetch(scope, _opts) do
    warn(scope, "invalid scope")
    nil
  end

  if Config.env() != :test do
    defp maybe_warn_not_fetched(scope, nil) do
      warn(
        Types.object_type(scope),
        "cannot lookup Settings since they aren't preloaded in scoped object"
      )

      nil
    end
  end

  defp maybe_warn_not_fetched(_, _), do: nil

  defp do_fetch(id) do
    query_filter(Bonfire.Data.Identity.Settings, %{id: id})
    # |> proload([:pointer]) # workaround for error "attempting to cast or change association `pointer` from `Bonfire.Data.Identity.Settings` that was not loaded. Please preload your associations before manipulating them through changesets"
    |> repo().maybe_one()
  end

  @doc """
  Put a setting using a key like `:key` or list of nested keys like `[:top_key, :sub_key]`
  """
  def put(keys, value, opts) when is_list(keys) do
    # keys = Config.keys_tree(keys) # Note: doing this in set/2 instead
    # |> debug("Putting settings for")
    map_put_in(keys, value)
    |> debug("map_put_in")
    |> input_to_atoms(
      discard_unknown_keys: true,
      values: true,
      values_to_integers: true,
      also_discard_unknown_nested_keys: false
    )
    |> debug("input_to_atoms")
    |> maybe_to_keyword_list(true)
    |> debug("maybe_to_keyword_list")
    |> set(opts)
  end

  def put(key, value, opts), do: put([key], value, opts)

  def map_put_in(root \\ %{}, keys, value) do
    # root = %{} or non empty map
    # keys = [:a, :b, :c]
    # value = 3
    put_in(root, Enum.map(keys, &Access.key(&1, %{})), value)
  end

  @doc """
  Set several settings at once.
  Accepts nested attributes as map with string keys (which are transformed into keyword list), or a keyword list.
  Determines what scope to use & sets/updates settings for it.
  """
  def set(attrs, opts) when is_map(attrs) do
    attrs
    |> input_to_atoms(
      discard_unknown_keys: true,
      values: true,
      values_to_integers: true,
      also_discard_unknown_nested_keys: false
    )
    |> debug("settings as atoms")
    |> set_with_hooks(to_options(opts))
  end

  def set(settings, opts) when is_list(settings) do
    # FIXME: optimise (do not convert to map and then back)
    Enum.into(settings, %{})
    |> set_with_hooks(to_options(opts))
  end

  def reset_instance() do
    with {:ok, set} <-
           repo().delete(struct(Bonfire.Data.Identity.Settings, id: id(instance_scope())), []) do
      # also put_env to cache it in Elixir's Config?
      # Config.put([])

      {:ok, set}
    end
  end

  def reset_all() do
    reset_instance()
    repo().delete_all(Bonfire.Data.Identity.Settings)
  end

  # TODO: find a better, more pluggable way to add hooks to settings
  defp set_with_hooks(
         %{Bonfire.Me.Users => %{undiscoverable: true}, scope: :user} = attrs,
         opts
       ) do
    current_user = current_user_required!(opts)

    do_set(attrs, opts)

    Bonfire.Boundaries.Controlleds.remove_acls(
      current_user,
      :guests_may_see_read
    )

    Bonfire.Boundaries.Controlleds.add_acls(
      current_user,
      :guests_may_read
    )
  end

  defp set_with_hooks(
         %{Bonfire.Me.Users => %{undiscoverable: _}, scope: :user} = attrs,
         opts
       ) do
    current_user = current_user_required!(opts)

    do_set(attrs, opts)

    Bonfire.Boundaries.Controlleds.remove_acls(
      current_user,
      :guests_may_read
    )

    Bonfire.Boundaries.Controlleds.add_acls(
      current_user,
      :guests_may_see_read
    )
  end

  defp set_with_hooks(attrs, opts) do
    do_set(attrs, opts)
  end

  defp do_set(attrs, opts) when is_map(attrs) do
    attrs
    |> maybe_to_keyword_list(true)
    |> do_set(opts)
  end

  defp do_set(settings, opts) when is_list(settings) do
    current_user = current_user(opts)
    current_account = current_account(opts)
    # FIXME: do we need to associate each setting key to a verb? (eg. :describe)
    is_admin =
      e(opts, :skip_boundary_check, nil) ||
        Bonfire.Boundaries.can?(current_account, :configure, :instance)

    scope =
      case maybe_to_atom(e(settings, :scope, nil) || e(opts, :scope, nil))
           |> debug("scope specified to set") do
        :instance when is_admin == true ->
          {:instance, instance_scope()}

        :instance ->
          raise(
            Bonfire.Fail,
            {:unauthorized,
             l("to change instance settings.") <> " " <> l("Please contact an admin.")}
          )

        :account ->
          {:current_account, current_account}

        :user ->
          {:current_user, current_user}

        %schema{} = scope when schema == Bonfire.Data.Identity.Account ->
          {:current_account, scope}

        %schema{} = scope when schema == Bonfire.Data.Identity.User ->
          {:current_user, scope}

        object when is_map(object) ->
          object

        _ ->
          if current_user do
            {:current_user, current_user}
          else
            if current_account do
              {:current_account, current_account}
            end
          end
      end

    debug(scope, "computed scope to set")

    if scope do
      settings
      |> Keyword.drop([:scope])
      |> Enum.map(&Config.keys_tree/1)
      |> debug("keyword list to set for #{inspect(scope)}")
      |> set_for(scope, ..., opts)

      # TODO: if setting a key to `nil` we could remove it instead
    else
      {:error, l("You need to be authenticated to change settings.")}
    end
  end

  defp set_for({:current_user, scoped} = _scope_tuple, settings, opts) do
    fetch_or_empty(scoped, opts)
    # |> debug
    |> upsert(settings, ulid(scoped))
    ~> {:ok,
     %{
       __context__: %{current_user: map_put_settings(scoped, ...)}
     }}
  end

  defp set_for({:current_account, scoped} = _scope_tuple, settings, opts) do
    fetch_or_empty(scoped, opts)
    # |> debug
    |> upsert(settings, ulid(scoped))
    ~> {:ok,
     %{
       __context__: %{current_account: map_put_settings(scoped, ...)}
       # TODO: assign this within current_user ?
     }}
  end

  defp set_for({:instance, scoped} = _scope_tuple, settings, opts) do
    with {:ok, %{data: data} = set} <-
           fetch_or_empty(scoped, opts)
           # |> debug
           |> upsert(settings, ulid(scoped)) do
      # also put_env to cache it in Elixir's Config
      Config.put(data)
      |> debug("put in config")

      {:ok, set}
    end
  end

  defp set_for({_, scope}, settings, opts) do
    set_for(scope, settings, opts)
  end

  defp set_for(scoped, settings, opts) do
    fetch_or_empty(scoped, opts)
    |> upsert(settings, ulid!(scoped))
  end

  defp map_put_settings(object, {:ok, settings}),
    do: map_put_settings(object, settings)

  defp map_put_settings(object, settings),
    do: Map.put(object, :settings, settings)

  defp fetch_or_empty(scoped, opts) do
    maybe_fetch(scoped, opts ++ [preload: true]) ||
      struct(Bonfire.Data.Identity.Settings)
  end

  defp upsert(
         %schema{data: existing_data} = settings,
         data,
         _
       )
       when (schema == Bonfire.Data.Identity.Settings and is_list(existing_data)) or
              is_map(existing_data) do
    data
    |> debug("new settings")

    existing_data
    # |> debug("existing_data")
    |> deep_merge(data, replace_lists: true)
    |> debug("merged settings to set")
    |> do_update(settings, ...)
  end

  defp upsert(
         %schema{id: id} = settings,
         data,
         _
       )
       when schema == Bonfire.Data.Identity.Settings and is_binary(id) do
    do_update(settings, data)
  end

  defp upsert(%{settings: _} = parent, data, _) do
    parent
    |> repo().maybe_preload(:settings)
    |> e(:settings, struct(Bonfire.Data.Identity.Settings))
    |> upsert(data, ulid(parent))
  end

  defp upsert(%schema{} = settings, data, scope_id)
       when schema == Bonfire.Data.Identity.Settings do
    %{id: ulid!(scope_id), data: data, json: prepare_for_json(data)}
    # |> debug()
    |> Bonfire.Data.Identity.Settings.changeset(settings, ...)
    |> info()
    |> repo().insert()
  rescue
    e in Ecto.ConstraintError ->
      warn(e, "ConstraintError - will next attempt to update instead")

      do_fetch(ulid!(scope_id))
      |> info("fetched")
      |> do_update(data)
  end

  defp do_update(
         %schema{} = settings,
         data
       )
       when schema == Bonfire.Data.Identity.Settings do
    Bonfire.Data.Identity.Settings.changeset(settings, %{data: data, json: prepare_for_json(data)})
    |> repo().update()
  end

  defp prepare_for_json(settings) do
    # WIP: https://github.com/bonfire-networks/bonfire-app/issues/790
    # |> info("attempt with JsonSerde")
    with {:ok, for_json} <-
           settings
           |> Map.new()
           |> JsonSerde.Serializer.serialize() do
      # prepare_from_json(for_json)
      for_json
    end
  end

  defp prepare_from_json(settings) do
    # WIP: https://github.com/bonfire-networks/bonfire-app/issues/790

    settings
    |> JsonSerde.Deserializer.deserialize(..., ...)
    # ~> info("deserialized")
    # TODO: add support for atom keys in Map to JsonSerde (see open PR there) so we can avoid needing input_to_atoms here?
    ~> input_to_atoms(
      discard_unknown_keys: true,
      values: false,
      also_discard_unknown_nested_keys: false
    )

    # |> info("to_atoms")
  end

  # def delete(key, opts \\ [])
  # def delete([key], opts), do: delete(key, opts)

  # def delete([parent_key | keys] = _keys_tree, opts) do
  #   {_, updated_parent} =
  #     get(parent_key, [])
  #     |> get_and_update_in(keys, fn _ -> :pop end)

  #   put(parent_key, updated_parent, opts)
  # end

  # def delete(key, opts) do
  #   # Config.delete(key, otp_app) # if scope==instance
  # end

  defp instance_scope,
    do: Bonfire.Boundaries.Circles.get_id(:local) || "3SERSFR0MY0VR10CA11NSTANCE"
end
