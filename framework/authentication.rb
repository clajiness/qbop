module Framework
  # Rodauth middleware for qbop's future browser authentication.
  class Authentication < Roda
    plugin :middleware

    plugin :rodauth do
      db { DB }
      enable :login, :logout, :create_account, :internal_request

      prefix '/auth'
      create_account_route nil
    end
    plugin :route_csrf, csrf_failure: :empty_403 # rubocop:disable Naming/VariableNumber

    route do |r|
      env['rodauth'] = rodauth

      r.on 'auth' do
        r.rodauth
      end
    end
  end
end
