require "rails_helper"

RSpec.describe "Api::V1::MyActivity", type: :request do
  let(:employee_a) { create(:coplan_user, name: "Employee A") }
  let(:employee_b) { create(:coplan_user, name: "Employee B") }
  let(:headers) { { "Authorization" => "Bearer test-token-employee-a" } }
  let(:plan) { create(:plan, :published, title: "Published plan", created_by_user: employee_b) }
  let(:thread_record) { create(:comment_thread, :with_anchor, plan: plan, created_by_user: employee_a) }

  before do
    create(:api_token, user: employee_a, raw_token: "test-token-employee-a", agent_name: "Claude")
  end

  def comment_on(thread, author:, at:, **attrs)
    create(:comment, comment_thread: thread, author_id: author.id, created_at: at, **attrs)
  end

  def json
    JSON.parse(response.body)
  end

  describe "GET /api/v1/me/comments" do
    it "requires a token" do
      get api_v1_my_comments_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns only the caller's comments, including ones their agent posted" do
      own = comment_on(thread_record, author: employee_a, at: 2.days.ago, body_markdown: "Mine")
      agent = comment_on(thread_record, author: employee_a, at: 1.day.ago, author_type: "local_agent", agent_name: "Claude")
      comment_on(thread_record, author: employee_b, at: 1.day.ago)
      comment_on(thread_record, author: employee_a, at: 1.day.ago, deleted_at: Time.current)

      get api_v1_my_comments_path, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["comments"].map { |c| c["id"] }).to eq([ own.id, agent.id ])
      expect(json["comments"].last).to include("author_type" => "local_agent", "agent_name" => "Claude")
      expect(json["next_cursor"]).to be_nil
    end

    it "includes the thread and plan context" do
      comment_on(thread_record, author: employee_a, at: 1.day.ago, body_markdown: "Mine")

      get api_v1_my_comments_path, headers: headers

      item = json["comments"].first
      expect(item["body_markdown"]).to eq("Mine")
      expect(item["thread"]).to include("id" => thread_record.id, "status" => "open", "anchor_text" => "Some content here")
      expect(item["thread"]["url"]).to end_with("?thread=#{thread_record.id}")
      expect(item["plan"]).to include("id" => plan.id, "title" => "Published plan", "visibility" => "published",
        "archived" => false, "created_by_user" => { "id" => employee_b.id, "name" => "Employee B" })
      expect(item["plan"]["url"]).to be_present
    end

    it "filters by since (inclusive) and until (exclusive)" do
      comment_on(thread_record, author: employee_a, at: Time.utc(2026, 1, 1) - 1.second)
      in_range = comment_on(thread_record, author: employee_a, at: Time.utc(2026, 1, 1))
      comment_on(thread_record, author: employee_a, at: Time.utc(2026, 7, 1))

      get api_v1_my_comments_path, params: { since: "2026-01-01", until: "2026-07-01T00:00:00Z" }, headers: headers

      expect(json["comments"].map { |c| c["id"] }).to eq([ in_range.id ])
    end

    it "pages oldest first with a cursor, including rows that share a timestamp" do
      at = Time.utc(2026, 3, 1)
      comments = 5.times.map { |i| comment_on(thread_record, author: employee_a, at: i < 3 ? at : at + i.minutes) }
      expected = comments.sort_by { |c| [ c.created_at, c.id ] }.map(&:id)

      seen = []
      cursor = nil
      3.times do
        get api_v1_my_comments_path, params: { limit: 2, cursor: cursor }.compact, headers: headers
        seen.concat(json["comments"].map { |c| c["id"] })
        cursor = json["next_cursor"]
        break unless cursor
      end

      expect(seen).to eq(expected)
      expect(cursor).to be_nil
    end

    it "leaves out other people's drafts but keeps the caller's own" do
      others_draft = create(:plan, :draft, created_by_user: employee_b)
      own_draft = create(:plan, :draft, created_by_user: employee_a)
      comment_on(create(:comment_thread, plan: others_draft, created_by_user: employee_a), author: employee_a, at: 1.day.ago)
      kept = comment_on(create(:comment_thread, plan: own_draft, created_by_user: employee_a), author: employee_a, at: 1.day.ago)

      get api_v1_my_comments_path, headers: headers

      expect(json["comments"].map { |c| c["id"] }).to eq([ kept.id ])
    end

    it "keeps comments on archived plans and says so" do
      archived = create(:plan, :archived, created_by_user: employee_b)
      comment_on(create(:comment_thread, plan: archived, created_by_user: employee_a), author: employee_a, at: 1.day.ago)

      get api_v1_my_comments_path, headers: headers

      expect(json["comments"].first["plan"]).to include("id" => archived.id, "archived" => true)
    end

    it "rejects a bad date, cursor, or param shape with 422" do
      far_future_cursor = Base64.urlsafe_encode64("99999-01-01T00:00:00Z|abc", padding: false)
      [
        { since: "last year" }, { since: "10000-01-01" }, { since: [ "2026-01-01" ] },
        { cursor: "nope" }, { cursor: far_future_cursor }, { cursor: [ "x" ] }
      ].each do |bad|
        get api_v1_my_comments_path, params: bad, headers: headers
        expect(response).to have_http_status(:unprocessable_content), "expected 422 for #{bad.inspect}"
      end
    end

    it "clamps an odd limit instead of failing" do
      comment_on(thread_record, author: employee_a, at: 1.day.ago)

      [ "abc", "0", "-1", [ "1" ] ].each do |limit|
        get api_v1_my_comments_path, params: { limit: limit }, headers: headers
        expect(response).to have_http_status(:ok), "expected 200 for limit=#{limit.inspect}"
      end
    end
  end

  describe "GET /api/v1/me/review_responses" do
    def respond_as(reviewer, plan:, at:, **attrs)
      request = create(:review_request, plan: plan, reviewer: reviewer)
      create(:review_response, review_request: request, created_at: at, **attrs)
    end

    it "requires a token" do
      get api_v1_my_review_responses_path
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the caller's own decisions with plan context, filtered by date" do
      own = respond_as(employee_a, plan: plan, at: Time.utc(2026, 2, 1))
      respond_as(employee_a, plan: create(:plan, :published, created_by_user: employee_b), at: Time.utc(2025, 12, 31))
      respond_as(employee_b, plan: create(:plan, :published, created_by_user: employee_a), at: Time.utc(2026, 2, 1))
      respond_as(employee_a, plan: create(:plan, :draft, created_by_user: employee_b), at: Time.utc(2026, 2, 1))

      get api_v1_my_review_responses_path, params: { since: "2026-01-01" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(json["review_responses"].map { |r| r["id"] }).to eq([ own.id ])
      expect(json["review_responses"].first).to include("decision" => "approved", "revision" => plan.current_revision,
        "actor_type" => "human", "review_request" => include("requirement" => "required"),
        "plan" => include("id" => plan.id, "title" => "Published plan"))
      expect(json["next_cursor"]).to be_nil
    end

    it "pages with a cursor, including rows that share a timestamp" do
      at = Time.utc(2026, 2, 1)
      responses = 3.times.map { respond_as(employee_a, plan: create(:plan, :published, created_by_user: employee_b), at: at) }
      expected = responses.sort_by(&:id).map(&:id)

      get api_v1_my_review_responses_path, params: { limit: 2 }, headers: headers
      seen = json["review_responses"].map { |r| r["id"] }

      get api_v1_my_review_responses_path, params: { limit: 2, cursor: json["next_cursor"] }, headers: headers
      seen.concat(json["review_responses"].map { |r| r["id"] })

      expect(seen).to eq(expected)
      expect(json["next_cursor"]).to be_nil
    end
  end
end
