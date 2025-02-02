defmodule NervesHubWebCore.Accounts do
  import Ecto.Query
  alias Ecto.{Changeset, Multi}
  alias Ecto.UUID

  alias NervesHubWebCore.Accounts.{
    Org,
    User,
    UserCertificate,
    Invite,
    OrgKey,
    OrgLimit,
    OrgUser,
    OrgMetric
  }

  alias NervesHubWebCore.Products.{Product, ProductUser}
  alias NervesHubWebCore.Repo
  alias Comeonin.Bcrypt

  @spec create_org(User.t(), map) ::
          {:ok, Org.t()}
          | {:error, Changeset.t()}
  def create_org(%User{} = user, params) do
    multi =
      Multi.new()
      |> Multi.insert(:org, Org.creation_changeset(%Org{}, params))
      |> Multi.insert(:org_user, fn %{org: org} ->
        org_user = %OrgUser{
          org_id: org.id,
          user_id: user.id,
          role: :admin
        }

        Org.add_user(org_user, %{})
      end)

    case Repo.transaction(multi) do
      {:ok, result} ->
        {:ok, result.org}

      {:error, :org, changeset, _} ->
        {:error, changeset}
    end
  end

  def create_org_limit(params) do
    %OrgLimit{}
    |> OrgLimit.changeset(params)
    |> Repo.insert()
  end

  def delete_org_limit(%OrgLimit{} = org_limit) do
    org_limit
    |> Repo.delete()
  end

  def update_org_limit(org_limit, params) do
    org_limit
    |> OrgLimit.update_changeset(params)
    |> Repo.update()
  end

  @doc """
  Returns a map of limits for the org identified by `org_id`.
  """
  @spec get_org_limit_by_org_id(Org.id()) :: OrgLimit.t()
  def get_org_limit_by_org_id(org_id) do
    query = from(ol in OrgLimit, where: ol.org_id == ^org_id)

    query
    |> Repo.one()
    |> case do
      nil -> %OrgLimit{}
      org_limit -> org_limit
    end
  end

  def change_user(user, params \\ %{})

  def change_user(%User{id: nil} = user, params) do
    User.creation_changeset(user, params)
  end

  def change_user(%User{} = user, params) do
    User.update_changeset(user, params)
  end

  def create_user(user_params) do
    org_params = %{name: user_params[:username], type: :user}

    multi =
      Multi.new()
      |> Multi.insert(:user, User.creation_changeset(%User{}, user_params))
      |> Multi.insert(:org, Org.creation_changeset(%Org{}, org_params))
      |> Multi.insert(:org_user, fn %{user: user, org: org} ->
        org_user = %OrgUser{
          org_id: org.id,
          user_id: user.id,
          role: :admin
        }

        Org.add_user(org_user, %{})
      end)

    case Repo.transaction(multi) do
      {:ok, result} ->
        {:ok, result.user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  def add_org_user(%Org{} = org, %User{} = user, params) do
    org_user = %OrgUser{org_id: org.id, user_id: user.id}

    multi =
      Multi.new()
      |> Multi.insert(:org_user, Org.add_user(org_user, params))

    case Repo.transaction(multi) do
      {:ok, result} ->
        {:ok, Repo.preload(result.org_user, :user)}

      {:error, :org_user, changeset, _} ->
        {:error, changeset}
    end
  end

  def remove_org_user(%Org{type: :user, name: name}, %User{username: name}),
    do: {:error, :user_org}

  def remove_org_user(%Org{} = org, %User{} = user) do
    count = Repo.aggregate(Ecto.assoc(org, :org_users), :count, :id)

    if count == 1 do
      {:error, :last_user}
    else
      org_user = Repo.get_by(Ecto.assoc(org, :org_users), user_id: user.id)

      if org_user do
        {:ok, _result} =
          Multi.new()
          |> Multi.delete(:org_user, org_user)
          |> Repo.transaction()
      end

      :ok
    end
  end

  def change_org_user_role(%OrgUser{} = ou, role) do
    ou
    |> Org.change_user_role(%{role: role})
    |> Repo.update()
  end

  def get_org_user(org, user) do
    from(
      ou in OrgUser,
      where:
        ou.org_id == ^org.id and
          ou.user_id == ^user.id
    )
    |> OrgUser.with_user()
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      org_user -> {:ok, org_user}
    end
  end

  def get_org_users(org) do
    from(
      ou in OrgUser,
      where: ou.org_id == ^org.id,
      order_by: [desc: ou.role]
    )
    |> OrgUser.with_user()
    |> Repo.all()
  end

  def has_org_role?(org, user, role) do
    from(
      ou in OrgUser,
      where: ou.org_id == ^org.id,
      where: ou.user_id == ^user.id,
      where: ou.role in ^User.role_or_higher(role),
      select: count(ou.id) >= 1
    )
    |> Repo.one()
  end

  def get_user_orgs(%User{} = user) do
    Repo.all(Ecto.assoc(user, :orgs))
  end

  def get_user_orgs_with_product_role(%User{} = user, product_role) do
    q =
      from(
        o in Org,
        full_join: p in Product,
        on: p.org_id == o.id,
        full_join: ou in OrgUser,
        on: ou.org_id == o.id,
        full_join: pu in ProductUser,
        on: pu.product_id == p.id,
        where:
          ou.user_id == ^user.id or
            (pu.user_id == ^user.id and
               pu.role in ^User.role_or_higher(product_role)),
        group_by: o.id
      )

    Repo.all(q)
  end

  @spec create_user_certificate(User.t(), map) ::
          {:ok, User.t()}
          | {:error, Changeset.t()}
  def create_user_certificate(%User{} = user, params) do
    user
    |> Ecto.build_assoc(:user_certificates)
    |> UserCertificate.changeset(params)
    |> Repo.insert()
  end

  @doc """
  Authenticates a user by their email and password. Returns the user if the
  user is found and the password is correct, otherwise nil.
  """
  @spec authenticate(String.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :authentication_failed}
  def authenticate(email, password) do
    user = Repo.get_by(User, email: email)

    with %User{} <- user,
         true <- Bcrypt.checkpw(password, user.password_hash) do
      {:ok, user |> User.with_default_org() |> User.with_org_keys()}
    else
      nil ->
        # User wasn't found; do dummy check to make user enumeration more difficult
        Bcrypt.dummy_checkpw()
        {:error, :authentication_failed}

      false ->
        {:error, :authentication_failed}
    end
  end

  @spec get_user(integer()) ::
          {:ok, User.t()}
          | {:error, :not_found}
  def get_user(user_id) do
    query = from(u in User, where: u.id == ^user_id)

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def get_user!(user_id), do: Repo.get!(User, user_id)

  def get_user_with_all_orgs(user_id) do
    query = from(u in User, where: u.id == ^user_id) |> User.with_all_orgs()

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def get_user_by_email(email) do
    Repo.get_by(User, email: email)
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def get_user_by_username(username) do
    Repo.get_by(User, username: username)
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec get_user_certificates(User.t()) ::
          {:ok, [UserCertificate.t()]}
          | {:error, :not_found}
  def get_user_certificates(%User{id: user_id}) do
    query = from(uc in UserCertificate, where: uc.user_id == ^user_id)

    query
    |> Repo.all()
  end

  def get_user_certificate!(%User{id: user_id}, cert_id) do
    query = from(uc in UserCertificate, where: uc.user_id == ^user_id, where: uc.id == ^cert_id)

    query
    |> Repo.one!()
  end

  @spec get_user_certificate(User.t(), integer()) ::
          {:ok, UserCertificate.t()}
          | {:error, :not_found}
  def get_user_certificate(%User{id: user_id}, cert_id) do
    query = from(uc in UserCertificate, where: uc.user_id == ^user_id, where: uc.id == ^cert_id)

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      cert -> {:ok, cert}
    end
  end

  @spec delete_user_certificate(UserCertificate.t()) ::
          {:ok, UserCertificate.t()}
          | {:error, Changeset.t()}
  def delete_user_certificate(%UserCertificate{} = cert) do
    Repo.delete(cert)
  end

  def get_user_by_certificate_serial(serial) do
    case get_user_certificate_by_serial(serial) do
      {:ok, %{user: user}} -> User.with_default_org(user)
      error -> error
    end
  end

  def get_user_certificate_by_serial(serial) do
    query =
      from(
        uc in UserCertificate,
        where: uc.serial == ^serial,
        preload: [:user]
      )

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      cert -> {:ok, cert}
    end
  end

  def update_user_certificate(%UserCertificate{} = certificate, params) do
    certificate
    |> UserCertificate.update_changeset(params)
    |> Repo.update()
  end

  @spec get_user_with_password_reset_token(String.t()) ::
          {:ok, User.t()}
          | {:error, :not_found}
  def get_user_with_password_reset_token(token) when is_binary(token) do
    query =
      from(
        u in User,
        where: u.password_reset_token == ^token,
        where: u.password_reset_token_expires >= ^DateTime.utc_now()
      )

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @spec get_org(integer()) ::
          {:ok, Org.t()}
          | {:error, :org_not_found}
  def get_org(id) do
    Org
    |> Repo.get(id)
    |> case do
      nil -> {:error, :org_not_found}
      org -> {:ok, org}
    end
  end

  def get_org!(id), do: Repo.get!(Org, id)

  def get_org_with_org_keys(id) do
    Org
    |> Repo.get(id)
    |> case do
      nil -> {:error, :not_found}
      org -> {:ok, org |> Org.with_org_keys()}
    end
  end

  def get_org_by_name(org_name) do
    Org
    |> Repo.get_by(name: org_name)
    |> case do
      nil -> {:error, :org_not_found}
      org -> {:ok, org}
    end
  end

  def get_org_by_name_and_user(org_name, %User{id: user_id}) do
    query =
      from(
        o in Org,
        join: u in assoc(o, :users),
        where: u.id == ^user_id and o.name == ^org_name
      )

    Repo.one(query)
    |> case do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  @spec update_org(Org.t(), map) ::
          {:ok, Org.t()}
          | {:error, Changeset.t()}
  def update_org(%Org{} = org, attrs) do
    org
    |> Org.update_changeset(attrs)
    |> Repo.update()
  end

  @spec create_org_key(map) ::
          {:ok, OrgKey.t()}
          | {:error, Changeset.t()}
  def create_org_key(attrs) do
    %OrgKey{}
    |> change_org_key(attrs)
    |> Repo.insert()
  end

  def list_org_keys(%Org{id: org_id}) do
    query = from(tk in OrgKey, where: tk.org_id == ^org_id)

    query
    |> Repo.all()
  end

  def get_org_key(%Org{id: org_id}, tk_id) do
    get_org_key_query(org_id, tk_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  def get_org_key!(%Org{id: org_id}, tk_id) do
    get_org_key_query(org_id, tk_id)
    |> Repo.one!()
  end

  defp get_org_key_query(org_id, tk_id) do
    from(
      tk in OrgKey,
      where: tk.org_id == ^org_id,
      where: tk.id == ^tk_id
    )
  end

  def get_org_key_by_name(%Org{id: org_id}, name) do
    query =
      from(
        k in OrgKey,
        where: k.org_id == ^org_id,
        where: k.name == ^name
      )

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  def update_org_key(%OrgKey{} = org_key, params) do
    org_key
    |> change_org_key(params)
    |> Repo.update()
  end

  def delete_org_key(%OrgKey{} = org_key) do
    org_key
    |> OrgKey.delete_changeset(%{})
    |> Repo.delete()
  end

  def change_org_key(org_key, params \\ %{})

  def change_org_key(%OrgKey{id: nil} = org_key, params) do
    OrgKey.changeset(org_key, params)
  end

  def change_org_key(%OrgKey{id: _id} = org_key, params) do
    OrgKey.update_changeset(org_key, params)
  end

  @spec add_or_invite_to_org(%{required(String.t()) => String.t()}, Org.t()) ::
          {:ok, Invite.t()}
          | {:ok, OrgUser.t()}
          | {:error, Changeset.t()}
  def add_or_invite_to_org(%{"email" => email} = params, org) do
    case get_user_by_email(email) do
      {:error, :not_found} -> invite(params, org)
      {:ok, user} -> add_org_user(org, user, %{role: :admin})
    end
  end

  @spec invite(%{email: String.t()}, Org.t()) ::
          {:ok, Invite.t()}
          | {:error, Changeset.t()}
  def invite(params, org) do
    params = Map.merge(params, %{"org_id" => org.id, "token" => Ecto.UUID.generate()})

    %Invite{}
    |> Invite.changeset(params)
    |> Repo.insert()
  end

  @spec get_valid_invite(String.t()) ::
          {:ok, Invite.t()}
          | {:error, :invite_not_found}
  def get_valid_invite(token) do
    query =
      from(
        i in Invite,
        where: i.token == ^token,
        where: i.accepted == false,
        where: i.inserted_at >= fragment("NOW() - INTERVAL '48 hours'")
      )

    query
    |> Repo.one()
    |> case do
      nil -> {:error, :invite_not_found}
      invite -> {:ok, invite}
    end
  end

  @spec create_user_from_invite(Invite.t(), Org.t(), map()) ::
          {:ok, User.t()}
          | {:error}
  def create_user_from_invite(invite, org, user_params) do
    user_params = Map.put(user_params, :email, invite.email)

    Repo.transaction(fn ->
      with {:ok, user} <- create_user(user_params),
           {:ok, user} <- add_org_user(org, user, %{role: :admin}),
           {:ok, _invite} <- set_invite_accepted(invite) do
        {:ok, user}
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  @spec update_user(User.t(), map) ::
          {:ok, User.t()}
          | {:error, Changeset.t()}
  def update_user(%User{} = user, user_params) do
    user
    |> change_user(user_params)
    |> Repo.update()
  end

  defp set_invite_accepted(invite) do
    invite
    |> Invite.changeset(%{accepted: true})
    |> Repo.update()
  end

  @spec update_password_reset_token(String.t()) :: :ok
  def update_password_reset_token(email) when is_binary(email) do
    query = from(u in User, where: u.email == ^email)

    query
    |> Repo.one()
    |> case do
      nil ->
        {:error, :no_user}

      %User{} = user ->
        user
        |> change_user(%{password_reset_token: UUID.generate()})
        |> Repo.update()
    end
  end

  @spec reset_password(String.t(), map) ::
          {:ok, User.t()}
          | {:error, :not_found}
  def reset_password(reset_password_token, params) do
    reset_password_token
    |> get_user_with_password_reset_token()
    |> case do
      {:ok, user} ->
        user
        |> User.password_changeset(params)
        |> Repo.update()

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec user_in_org?(integer(), integer()) :: boolean()
  def user_in_org?(user_id, org_id) do
    from(ou in OrgUser,
      where: ou.user_id == ^user_id and ou.org_id == ^org_id,
      select: %{}
    )
    |> Repo.one()
    |> case do
      nil -> false
      _ -> true
    end
  end

  def create_org_metrics(run_utc_time) do
    q =
      from(
        o in Org,
        select: o.id
      )

    today = Date.utc_today()

    case DateTime.from_iso8601("#{today}T#{run_utc_time}Z") do
      {:ok, timestamp, _} ->
        Repo.all(q)
        |> Enum.each(&create_org_metric(&1, timestamp))

      error ->
        error
    end
  end

  def create_org_metric(org_id, timestamp) do
    devices = NervesHubWebCore.Devices.get_device_count_by_org_id(org_id)

    bytes_stored =
      NervesHubWebCore.Firmwares.get_firmware_by_org_id(org_id)
      |> Enum.reduce(0, &(&1.size + &2))

    params = %{
      org_id: org_id,
      devices: devices,
      bytes_stored: bytes_stored,
      timestamp: timestamp
    }

    %OrgMetric{}
    |> OrgMetric.changeset(params)
    |> Repo.insert()
  end
end
