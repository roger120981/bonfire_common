defmodule Bonfire.Common.RepoTemplate do
  use Arrows

  defmacro __using__(_) do
    quote do
      import Bonfire.Common.Config, only: [repo: 0]
      alias Bonfire.Common.Utils

      use Ecto.Repo,
        otp_app: Bonfire.Common.Config.get!(:otp_app),
        adapter: Ecto.Adapters.Postgres

      import Ecto.Query
      import Untangle
      use Arrows

      alias Pointers.Changesets
      alias Pointers.Pointer

      alias Ecto.Changeset

      @default_cursor_fields [cursor_fields: [{:id, :desc}]]

      @doc """
      Run a transaction, similar to `Repo.transaction/1`, but it expects an ok or error
      tuple. If an error tuple is returned, the transaction is aborted.
      """
      @spec transact_with(fun :: (() -> {:ok, any} | {:error, any})) ::
              {:ok, any} | {:error, any}
      def transact_with(fun) do
        transaction(fn ->
          ret = fun.()

          case ret do
            :ok -> :ok
            {:ok, v} -> v
            {:error, reason} -> rollback_error(reason)
            {:error, reason, extra} -> rollback_error(reason, extra)
            _ -> rollback_unexpected(ret)
          end
        end)
      rescue
        exception in Postgrex.Error ->
          handle_postgrex_exception(exception, __STACKTRACE__)
      end

      # def transact_with(fun) do
      #   transaction fn ->
      #     case fun.() do
      #       {:ok, val} -> val
      #       {:error, val} -> rollback(val)
      #       val -> val # naughty
      #     end
      #   end
      # end

      @doc """
      Like `insert/1`, but understands remapping changeset errors to attr
      names from config (and only config, no overrides at present!)
      """
      def put(%Changeset{} = changeset) do
        with {:error, changeset} <- insert(changeset) do
          Changesets.rewrite_constraint_errors(changeset)
        end
      rescue
        exception in Postgrex.Error ->
          handle_postgrex_exception(exception, __STACKTRACE__)
      end

      def put_many(things) do
        case Enum.filter(things, fn {_, %Changeset{valid?: v}} -> not v end) do
          [] -> transact_with(fn -> put_many(things, %{}) end)
          failed -> {:error, failed}
        end
      end

      defp put_many([], acc), do: {:ok, acc}

      defp put_many([{k, v} | is], acc) do
        case insert(v) do
          {:ok, v} -> put_many(is, Map.put(acc, k, v))
          {:error, other} -> {:error, {k, other}}
        end
      end

      def upsert(cs, keys_or_attrs_to_update \\ nil, conflict_target \\ [:id])

      def upsert(cs, attrs, conflict_target)
          when is_map(attrs) do
        upsert(cs, Map.to_list(attrs), conflict_target)
      end

      def upsert(cs, keys, conflict_target)
          when (is_list(keys) and is_struct(cs)) or is_atom(cs) do
        debug(keys, "update keys")

        keys =
          if not Keyword.keyword?(keys) do
            Enum.map(keys, &{&1, Ecto.Changeset.get_field(cs, &1)})
          else
            keys
          end

        insert_or_update(
          cs,
          # on_conflict: {:replace_all_except, conflict_target},
          on_conflict: [set: keys],
          conflict_target: conflict_target
        )
      end

      def upsert(cs, nil, conflict_target) do
        debug("replace_all_except")

        insert_or_update(
          cs,
          on_conflict: :nothing
          # conflict_target: conflict_target
        )
      end

      def upsert_all(schema, data, conflict_target \\ [:id]) when is_atom(schema) do
        insert_all(
          schema,
          data,
          on_conflict: {:replace_all_except, conflict_target},
          conflict_target: conflict_target
        )
      end

      def insert_or_ignore(cs) when is_struct(cs) or is_atom(cs) do
        cs
        # FIXME?
        |> Map.put(:repo_opts, on_conflict: :ignore)
        # |> debug("insert_or_ignore cs")
        |> insert(on_conflict: :nothing)
      rescue
        exception in Postgrex.Error ->
          handle_postgrex_exception(exception, __STACKTRACE__)
      end

      def insert_all_or_ignore(schema, data) when is_atom(schema) do
        insert_all(schema, data, on_conflict: :nothing)
      rescue
        exception in Postgrex.Error ->
          handle_postgrex_exception(exception, __STACKTRACE__)
      end

      @doc """
      Like Repo.one, but returns an ok/error tuple.
      """
      def single(q) do
        one(limit(q, 1)) |> ret_single()
      rescue
        exception in Postgrex.Error ->
          handle_postgrex_exception(exception, __STACKTRACE__)
      end

      defp ret_single(nil), do: {:error, :not_found}
      defp ret_single(other), do: {:ok, other}

      @doc """
      Like Repo.single, except on failure, adds an error to the changeset
      """
      def find(q, changeset, field \\ :form), do: ret_find(one(q), changeset, field)

      defp ret_find(nil, changeset, field),
        do: {:error, Changeset.add_error(changeset, field, "not_found")}

      defp ret_find(other, _changeset, _field), do: {:ok, other}

      @doc "Like Repo.get, but returns an ok/error tuple"
      @spec fetch(atom, integer | binary) :: {:ok, atom} | {:error, :not_found}
      def fetch(queryable, id) do
        case get(queryable, id) do
          nil -> {:error, :not_found}
          thing -> {:ok, thing}
        end
      end

      @doc "Like Repo.get_by, but returns an ok/error tuple"
      def fetch_by(queryable, term) do
        case get_by(queryable, term) do
          nil -> {:error, :not_found}
          thing -> {:ok, thing}
        end
      end

      def fetch_all(queryable, ids) when is_binary(ids) do
        queryable
        |> where([t], t.id in ^ids)
        |> all()
      end

      defp pagination_defaults,
        do: [
          # sets the default limit TODO: put in config
          limit: Bonfire.Common.Config.get(:default_pagination_limit, 10),
          # sets the maximum limit TODO: put in config
          maximum_limit: 200,
          # include total count by default?
          include_total_count: false,
          # sets the total_count_primary_key_field to uuid for calculating total_count
          total_count_primary_key_field: Pointers.ULID
        ]

      defp paginator_paginate(queryable, opts \\ @default_cursor_fields, repo_opts \\ [])

      defp paginator_paginate(queryable, opts, repo_opts) when is_list(opts) do
        opts =
          (opts[:paginate] || opts[:paginated] || opts[:pagination] || opts)
          |> Keyword.new()

        # info(opts, "opts")
        Keyword.merge(
          pagination_defaults(),
          Keyword.merge(@default_cursor_fields, opts)
        )
        # |> debug("merged opts")
        |> Paginator.paginate(queryable, ..., __MODULE__, repo_opts)
      end

      defp paginator_paginate(queryable, opts, repo_opts)
           when is_map(opts) and not is_struct(opts) do
        # info(opts, "opts")
        paginator_paginate(queryable, Utils.to_options(opts), repo_opts)
      end

      defp paginator_paginate(queryable, _, repo_opts) do
        paginator_paginate(queryable, @default_cursor_fields, repo_opts)
      end

      @doc """
      Different implementation for pagination using Scrivener (used by eg. rauversion)
      """
      def paginate(pageable, options \\ []) do
        Scrivener.paginate(
          pageable,
          Scrivener.Config.new(__MODULE__, [page_size: 10], options)
        )
      end

      @doc """
      Main implementation for pagination using Paginator (used by most extensions)
      """
      def many_paginated(queryable, opts \\ [], repo_opts \\ [])

      def many_paginated(%{order_bys: order} = queryable, opts, repo_opts)
          when is_list(order) and length(order) > 0 do
        # info(opts, "opts")
        # debug(order, "order_bys")
        paginator_paginate(queryable, opts, repo_opts)
      end

      def many_paginated(queryable, opts, repo_opts) do
        # info(opts, "opts")
        queryable
        |> order_by([o],
          desc: o.id
        )
        |> paginator_paginate(opts, repo_opts)
      end

      def many(query, opts \\ []) do
        all(query, opts)
      rescue
        exception in Postgrex.Error ->
          handle_postgrex_exception(exception, __STACKTRACE__)
      end

      def delete_many(query) do
        query
        |> Ecto.Query.exclude(:order_by)
        |> delete_all()
      end

      defp handle_postgrex_exception(exception, stacktrace, changeset \\ nil)

      defp handle_postgrex_exception(
             %{postgres: %{code: :undefined_file} = pg},
             _,
             nil
           ) do
        error(
          pg,
          "Database error, probably a missing extension (eg. if using geolocation, you need to run Postgis)"
        )

        {:error, :missing_db_extension}
      end

      # defp handle_postgrex_exception(
      #        %{postgres: %{code: :integrity_constraint_violation}},
      #        _,
      #        changeset
      #      ) do
      #   {:error, %{changeset | valid?: false}}
      # end

      defp handle_postgrex_exception(exception, stacktrace, _) do
        reraise(exception, stacktrace)
      end

      defp rollback_error(reason, extra \\ nil) do
        error(reason, "transact_with_error")
        if extra, do: debug(extra, "transact_with_error_extra")
        rollback(reason)
      end

      defp rollback_unexpected(ret) do
        error(
          "Repo transaction expected one of `:ok` `{:ok, value}` `{:error, reason}` `{:error, reason, extra}` but got: #{inspect(ret)}"
        )

        rollback("transact_with_unexpected_case")
      end

      def transact_many([]), do: {:ok, []}

      def transact_many(queries) when is_list(queries) do
        transaction(fn -> Enum.map(queries, &transact/1) end)
      end

      defp transact({:all, q}), do: many(q)
      defp transact({:count, q}), do: aggregate(q, :count)
      defp transact({:one, q}), do: one(q)

      defp transact({:one!, q}) do
        {:ok, ret} = single(q)
        ret
      end

      def sql(raw_sql, data \\ [], opts \\ []) do
        Ecto.Adapters.SQL.query!(__MODULE__, raw_sql, data, opts)
      end

      defdelegate maybe_preload(obj, preloads, opts \\ []),
        to: Bonfire.Common.Repo.Preload
    end
  end
end