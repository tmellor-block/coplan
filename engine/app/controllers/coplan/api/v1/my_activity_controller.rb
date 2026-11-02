module CoPlan
  module Api
    module V1
      # The caller's own comments and review decisions across every plan,
      # by date — one paged call instead of walking every plan's comments
      # and review requests. Always the caller: there is no author param,
      # so nobody can page through someone else's history here.
      #
      # Only plans the caller could find in a list (Plan.visible_to): a
      # comment left on someone else's draft drops out until it's published.
      #
      # Oldest first. `next_cursor` is opaque; pass it back as `cursor` with
      # the same since/until to get the next page. Null means done.
      class MyActivityController < BaseController
        DEFAULT_LIMIT = 100
        MAX_LIMIT = 200

        # What plan_json reads: the address walks the placement's library
        # and folder ancestors (same shape PlansController#index preloads).
        PLAN_INCLUDES = [
          :created_by_user,
          { placement: [ :library, { folder: { parent: { parent: { parent: :parent } } } } ] }
        ].freeze

        class InvalidParam < StandardError; end

        rescue_from InvalidParam do |error|
          render json: { error: error.message }, status: :unprocessable_content
        end

        # GET /api/v1/me/comments
        def comments
          scope = Comment.kept
            .where(author_id: current_user.id, author_type: %w[human local_agent])
            .joins(comment_thread: :plan)
            .merge(Plan.visible_to(current_user))
            .includes(comment_thread: { plan: PLAN_INCLUDES })
          records, next_cursor = paginate(scope)

          render json: { comments: records.map { |c| comment_json(c) }, next_cursor: next_cursor }
        end

        # GET /api/v1/me/review_responses
        def review_responses
          scope = ReviewResponse
            .where(user_id: current_user.id)
            .joins(review_request: :plan)
            .merge(Plan.visible_to(current_user))
            .includes(:plan_version, review_request: { plan: PLAN_INCLUDES })
          records, next_cursor = paginate(scope)

          render json: { review_responses: records.map { |r| review_response_json(r) }, next_cursor: next_cursor }
        end

        private

        # Keyset paging on (created_at, id). Ids alone aren't time-ordered
        # (older rows have random UUIDs), so the cursor carries both.
        def paginate(scope)
          table = scope.klass.arel_table
          since_time = time_param(:since)
          until_time = time_param(:until)
          scope = scope.where(table[:created_at].gteq(since_time)) if since_time
          scope = scope.where(table[:created_at].lt(until_time)) if until_time

          if params[:cursor].present?
            at, id = decode_cursor(params[:cursor].to_s)
            scope = scope.where(table[:created_at].gt(at).or(table[:created_at].eq(at).and(table[:id].gt(id))))
          end

          limit = params[:limit].present? ? params[:limit].to_s.to_i.clamp(1, MAX_LIMIT) : DEFAULT_LIMIT
          records = scope.order(table[:created_at].asc, table[:id].asc).limit(limit + 1).to_a
          next_cursor = encode_cursor(records[limit - 1]) if records.size > limit
          [ records.first(limit), next_cursor ]
        end

        def time_param(name)
          value = params[name].presence
          return unless value

          valid_time(Time.find_zone("UTC").iso8601(value.to_s))
        rescue ArgumentError
          raise InvalidParam, "#{name} must be an ISO 8601 date or timestamp"
        end

        # A year the database can't store would surface as a 500.
        def valid_time(time)
          raise ArgumentError unless (1000..9999).cover?(time.year)

          time
        end

        def encode_cursor(record)
          Base64.urlsafe_encode64("#{record.created_at.utc.iso8601(6)}|#{record.id}", padding: false)
        end

        def decode_cursor(cursor)
          at, id = Base64.urlsafe_decode64(cursor).split("|", 2)
          raise ArgumentError if id.blank?

          [ valid_time(Time.iso8601(at.to_s)), id ]
        rescue ArgumentError
          raise InvalidParam, "cursor is invalid; pass back next_cursor from the previous page"
        end

        def comment_json(comment)
          thread = comment.comment_thread
          {
            id: comment.id,
            body_markdown: comment.body_markdown,
            author_type: comment.author_type,
            agent_name: comment.agent_name,
            created_at: comment.created_at,
            thread: {
              id: thread.id,
              status: thread.status,
              anchor_text: thread.anchor_text,
              url: thread_url(thread)
            },
            plan: plan_json(thread.plan)
          }
        end

        def review_response_json(response)
          request = response.review_request
          {
            id: response.id,
            decision: response.decision,
            revision: response.plan_version.revision,
            note: response.note,
            actor_type: response.actor_type,
            agent_name: response.agent_name,
            comment_thread_id: response.comment_thread_id,
            created_at: response.created_at,
            review_request: { id: request.id, requirement: request.requirement, status: request.status },
            plan: plan_json(request.plan)
          }
        end

        def plan_json(plan)
          author = plan.created_by_user
          {
            id: plan.id,
            title: plan.title,
            url: plan_web_url(plan),
            visibility: plan.visibility,
            archived: plan.archived?,
            created_by_user: author && { id: author.id, name: author.name }
          }
        end

        def thread_url(thread)
          handle, slug_path = Urls::Canonical.split(thread.plan.url_path)
          browse_url(handle: handle, slug_path: slug_path, thread: thread.id)
        end
      end
    end
  end
end
