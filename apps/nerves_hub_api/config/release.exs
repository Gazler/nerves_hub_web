import Config

sync_nodes_optional =
  case System.fetch_env("SYNC_NODES_OPTIONAL") do
    {:ok, sync_nodes_optional} ->
      sync_nodes_optional
      |> String.trim()
      |> String.split(" ")
      |> Enum.map(&String.to_atom/1)

    :error ->
      []
  end

config :kernel,
  sync_nodes_optional: sync_nodes_optional,
  sync_nodes_timeout: 5000,
  inet_dist_listen_min: 9100,
  inet_dist_listen_max: 9155

config :rollbax, access_token: System.fetch_env!("ROLLBAR_ACCESS_TOKEN")

config :nerves_hub_web_core, NervesHubWebCore.Firmwares.Upload.S3,
  bucket: System.fetch_env!("S3_BUCKET_NAME")

config :nerves_hub_web_core, NervesHubWebCore.Firmwares.Transfer.S3Ingress,
  bucket: System.fetch_env!("S3_LOG_BUCKET_NAME")

config :ex_aws, region: System.fetch_env!("AWS_REGION")

config :nerves_hub_www, NervesHubWWW.Mailer,
  adapter: Bamboo.SMTPAdapter,
  server: System.fetch_env!("SES_SERVER"),
  port: System.fetch_env!("SES_PORT"),
  username: System.fetch_env!("SMTP_USERNAME"),
  password: System.fetch_env!("SMTP_PASSWORD")
