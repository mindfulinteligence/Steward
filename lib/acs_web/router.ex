defmodule AcsWeb.Router do
  use AcsWeb, :router

  import AcsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AcsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  pipeline :account_host do
    plug :require_account_host
  end

  pipeline :tenant_user do
    plug :require_tenant_user
  end

  pipeline :login_rate_limit do
    plug AcsWeb.Plugs.LoginRateLimit
  end

  scope "/docs", AcsWeb do
    pipe_through :browser

    get "/", DocsController, :show
    get "/:page", DocsController, :show
  end

  scope "/", AcsWeb do
    pipe_through [:browser, :account_host, :login_rate_limit, :redirect_if_authenticated]

    get "/auth/log_in", UserSessionController, :auth_log_in
    get "/users/log_in", UserSessionController, :new
    post "/users/log_in", UserSessionController, :create
  end

  scope "/", AcsWeb do
    pipe_through [:browser, :account_host]

    get "/auth/callback", UserSessionController, :callback
  end

  scope "/", AcsWeb do
    pipe_through :browser

    delete "/users/log_out", UserSessionController, :delete
    get "/auth/handoff", UserSessionController, :handoff_start
    get "/auth/handoff/complete", UserSessionController, :handoff_complete
  end

  scope "/", AcsWeb do
    pipe_through [:browser, :account_host, :require_auth]

    get "/auth/handoff/confirm", UserSessionController, :handoff_confirm

    live_session :account,
      session: {AcsWeb.UserAuth, :fetch_user_token, []},
      on_mount: [
        {AcsWeb.UserAuth, :ensure_authenticated},
        {AcsWeb.UserAuth, :ensure_account_host}
      ] do
      live "/onboarding", AcsLive.OnboardingLive, :index
      live "/invitations/:token", AcsLive.InvitationLive, :show
    end
  end

  live_session :acs,
    session: {AcsWeb.UserAuth, :fetch_user_token, []},
    on_mount: [
      {AcsWeb.UserAuth, :ensure_authenticated},
      {AcsWeb.UserAuth, :assign_org},
      {AcsWeb.UserAuth, :ensure_tenant_member}
    ] do
    scope "/", AcsWeb do
      pipe_through [:browser, :require_auth, :tenant_user]

      live "/", AcsLive.Index, :index
      live "/tools", AcsLive.Tools, :index
      live "/tools/requests", AcsLive.ToolRequests, :index
      live "/documents", AcsLive.SpecsLive, :index
      live "/skills", AcsLive.SkillsLive, :index
      live "/error-traces", AcsLive.ErrorTracesLive, :index
    end
  end

  scope "/", AcsWeb do
    pipe_through [:browser, :require_auth, :tenant_user]

    live_session :memory_governance,
      session: {AcsWeb.UserAuth, :fetch_user_token, []},
      on_mount: [
        {AcsWeb.UserAuth, :assign_org},
        {AcsWeb.UserAuth, :ensure_authenticated},
        {AcsWeb.UserAuth, :ensure_tenant_member},
        {AcsWeb.UserAuth, :ensure_org_admin}
      ] do
      live "/memories", AcsLive.MemoryLive, :index
    end

    live_session :org_admin,
      session: {AcsWeb.UserAuth, :fetch_user_token, []},
      on_mount: [
        {AcsWeb.UserAuth, :assign_org},
        {AcsWeb.UserAuth, :ensure_authenticated},
        {AcsWeb.UserAuth, :ensure_tenant_member},
        {AcsWeb.UserAuth, :ensure_org_admin}
      ] do
      live "/settings", AcsLive.SettingsLive, :index
      live "/settings/members", AcsLive.MembersLive, :index
      live "/settings/authority-levels", AcsLive.AuthorityLevelsLive, :index
      live "/settings/prompts", AcsLive.PromptsLive, :index
    end
  end
end
