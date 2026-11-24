# What an agent may read about issues: a fixed roster generated from the model
# (find_issues, count_issues, get_issue) over the columns declared here, plus
# one hand-written tool for the question equality filters cannot answer.
class IssueTools < ActiveAgent::SchemaTools
  model Issue

  filterable :status, :priority, :component, :assignee_id, :reporter_id, :duplicate_of_id, :created_at
  returns :id, :title, :body, :status, :priority, :component,
          :assignee_id, :reporter_id, :duplicate_of_id, :created_at, :updated_at

  # Declared after the allowlists above: each of those rebuilds the roster.
  register_tool "search_issues",
    description: "Search issue titles and descriptions for a word or phrase. Use it to look for an " \
                 "existing report before filing a new one. Returns at most 10 issues, most urgent first.",
    properties: {
      query: { type: "string", description: "A word or short phrase, e.g. \"gift card\"" },
      include_closed: { type: "boolean", description: "Also search resolved and closed issues (default false)" }
    },
    required: [ "query" ]

  def self.search_issues(query:, actor: nil, include_closed: false)
    return { error: "query is required" } if query.to_s.strip.empty?

    scope = include_closed ? relation_for(actor) : relation_for(actor).merge(Issue.active)
    # Any word may match, so "gift card checkout" finds an issue that says
    # "gift card" and "payment step".
    words = query.to_s.split.map { |word| word.gsub(/[^[:alnum:]'+-]/, "") }.select { |word| word.length > 2 }
    words = [ query.to_s.strip ] if words.empty?
    matches = words.map { |word| scope.matching(word) }.reduce(:or).by_urgency.limit(10)

    { results: matches.map { |issue| project(issue) }, count: matches.size }
  end
end
