module Service
  # Handles interactions with the GitHub API for the Service module.
  class Github
    def initialize
      @conn = faraday_conn
    end

    def get_most_recent_tag
      response = @conn.get do |req|
        req.url '/repos/clajiness/qbop/tags'
        req.headers['Accept'] = 'application/vnd.github+json'
      end

      JSON.parse(response.body).first['name'] if response.success?
    rescue StandardError
      nil
    end

    private

    def faraday_conn
      Faraday.new(
        url: 'https://api.github.com'
      )
    end
  end
end
