class IssuesController < ApplicationController
  before_action :set_issue, only: %i[show edit update destroy]

  def index
    @filters = params.permit(:status, :priority, :component, :assignee_id, :q).to_h.compact_blank
    @issues = filtered_issues.includes(:assignee, :reporter).by_urgency
    @counts = Issue.group(:status).count
  end

  def show
    @comment = @issue.comments.new
  end

  def new
    @issue = Issue.new(priority: "medium")
  end

  def create
    @issue = Issue.new(issue_params.merge(reporter: current_user))
    if @issue.save
      redirect_to @issue, notice: "Issue #{@issue.reference} filed."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @issue.update(issue_params)
      redirect_to @issue, notice: "Issue #{@issue.reference} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @issue.destroy!
    redirect_to issues_path, notice: "Issue #{@issue.reference} deleted."
  end

  private

  def set_issue
    @issue = Issue.find(params[:id])
  end

  def issue_params
    params.expect(issue: %i[title body status priority component assignee_id duplicate_of_id])
  end

  def filtered_issues
    scope = Issue.matching(@filters["q"])
    scope = @filters["status"] == "all" ? scope : scope.where(status: @filters["status"] || %w[open in_progress])
    scope = scope.where(priority: @filters["priority"]) if @filters["priority"]
    scope = scope.where(component: @filters["component"]) if @filters["component"]
    scope = scope.where(assignee_id: @filters["assignee_id"] == "none" ? nil : @filters["assignee_id"]) if @filters["assignee_id"]
    scope
  end
end
