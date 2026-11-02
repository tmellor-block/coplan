# This migration comes from co_plan (originally 20261102000000)
# Backs GET /api/v1/me/comments and /api/v1/me/review_responses, which
# list one person's own activity across every plan by date.
class AddAuthorActivityIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :coplan_comments, [ :author_id, :created_at, :id ]
    add_index :coplan_review_responses, [ :user_id, :created_at, :id ]
  end
end
