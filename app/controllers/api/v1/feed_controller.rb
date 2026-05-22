class Api::V1::FeedController < ApplicationController
  before_action :check_rate_limit

  RATE_LIMIT = 30
  WINDOW = 60
  CACHE_TTL = 5.minutes
  ALLOWED_CATEGORIES = %w[tech finance markets].freeze
  
  def index
    category = params[:category].to_s.downcase
    page = params[:page].to_i > 0 ? params[:page].to_i : 1
    limit = params[:limit].to_i > 0 ? params[:limit].to_i : 10

    if category.present? && !ALLOWED_CATEGORIES.include?(category)
      return render json: { error: "Invalid category" }, status: :bad_request
    end

    cache_key = "feed:#{category.presence || 'all'}:page:#{page}:limit:#{limit}"
    cached = Rails.cache.read(cache_key)

    if cached
      articles = cached
      cache_hit = true
    else
      articles = filtered_articles(category)
      start_index = (page - 1) * limit
      articles = articles.slice(start_index, limit) || []
      articles = articles.map { |article| article.slice("id", "title", "summary", "publishedAt", "source") }

      Rails.cache.write(cache_key, articles, expires_in: CACHE_TTL)
      cache_hit = false
    end

    render json: {
      data: articles,
      meta: {
        page: page,
        limit: limit,
        total: filtered_articles(category).size,
        cached: cache_hit
      },
      rateLimit: {
        remaining: @remaining_request,
        resetAt: @rest_time.utc.iso8601
      }
    }, status: :ok
  end

  private

  def mock_articles
    JSON.parse(File.read(Rails.root.join('db', 'data', 'article.json')))
  end

  def filtered_articles(category)
    articles = mock_articles["articles"]
    return articles unless category.present?

    articles.select { |art| art["category"]&.downcase == category }
  end

  def mock_articles
    JSON.parse(File.read(Rails.root.join('db', 'data', 'article.json')))
  end

  def check_rate_limit
    ip = request.remote_ip
    key = "rate_limit:#{ip}"

    current_count = REDIS.get(key).to_i

    if current_count >= RATE_LIMIT
      t = REDIS.ttl(key)
      response.set_header("Retry-After", t)
      render json: { error: "Rate limit exceeded" }, status: :too_many_requests
      return
    end

    if current_count.zero?
      REDIS.setex(key, WINDOW, 1)
      @remaining_request = RATE_LIMIT - 1
    else
      REDIS.incr(key)
      @remaining_request = RATE_LIMIT - (current_count + 1)
    end

    @rest_time = Time.now + REDIS.ttl(key)
  end
end
