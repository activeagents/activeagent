class CommentsController < ApplicationController
  def create
    issue = Issue.find(params[:issue_id])
    comment = issue.comments.new(params.expect(comment: [ :body ]).merge(author: current_user))
    if comment.save
      redirect_to issue_path(issue, anchor: "comment-#{comment.id}")
    else
      redirect_to issue, alert: "A comment needs some text."
    end
  end
end
