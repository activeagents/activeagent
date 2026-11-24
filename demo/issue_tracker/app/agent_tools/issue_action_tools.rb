# What an agent may change. Kept apart from IssueTools so reading and writing
# are granted separately in the agent editor.
#
# Every change is written to the issue's activity as a comment marked
# "via agent", in the name of the person the agent is acting for. That is why
# the class is declared over Comment: find_comments reads the trail back.
class IssueActionTools < ActiveAgent::SchemaTools
  model Comment

  filterable :issue_id, :author_id, :via_agent
  returns :id, :issue_id, :author_id, :body, :via_agent, :created_at

  CHANGEABLE = %i[status priority component assignee_id duplicate_of_id].freeze

  register_tool "create_issue",
    description: "File a new issue. Search for an existing report first.",
    properties: {
      title: { type: "string", description: "One line, under 140 characters" },
      body: { type: "string", description: "What happens, what was expected, how to reproduce" },
      priority: { type: "string", enum: Issue::PRIORITIES },
      component: { type: "string", enum: Issue::COMPONENTS }
    },
    required: [ "title" ]

  register_tool "update_issue",
    description: "Change an issue's status, priority, component, assignee, or mark it a duplicate of another issue.",
    properties: {
      id: { type: "integer", description: "The issue number" },
      status: { type: "string", enum: Issue::STATUSES },
      priority: { type: "string", enum: Issue::PRIORITIES },
      component: { type: "string", enum: Issue::COMPONENTS },
      assignee_id: { type: "integer", description: "A user id from find_users; 0 to unassign" },
      duplicate_of_id: { type: "integer", description: "The issue this one duplicates" },
      reason: { type: "string", description: "One sentence on why, recorded in the issue's activity" }
    },
    required: [ "id" ]

  register_tool "add_comment",
    description: "Add a comment to an issue.",
    properties: {
      issue_id: { type: "integer", description: "The issue number" },
      body: { type: "string", description: "The comment text" }
    },
    required: %w[issue_id body]

  class << self
    def create_issue(title:, actor: nil, body: nil, priority: nil, component: nil)
      person = acting_for(actor)
      issue = Issue.new(title: title, body: body, priority: priority.presence || "medium",
                        component: component.presence, reporter: person)
      return { error: issue.errors.full_messages.to_sentence } unless issue.save

      issue.comments.create!(author: person, via_agent: true, body: "Filed by the agent.")
      IssueTools.call("get_issue", actor: actor, id: issue.id)
    end

    def update_issue(id:, actor: nil, reason: nil, **changes)
      issue = Issue.find_by(id: id)
      return { error: "No issue found with id #{id}" } unless issue

      changes = changes.slice(*CHANGEABLE).compact
      return { error: "Nothing to change: give at least one of #{CHANGEABLE.join(", ")}" } if changes.empty?

      changes[:assignee_id] = nil if changes[:assignee_id].to_i.zero? && changes.key?(:assignee_id)
      issue.assign_attributes(changes)
      summary = describe(issue)
      return { error: issue.errors.full_messages.to_sentence } unless issue.save

      if summary.present?
        issue.comments.create!(author: acting_for(actor), via_agent: true,
                               body: [ summary, reason.presence ].compact.join("\n\n"))
      end
      IssueTools.call("get_issue", actor: actor, id: issue.id)
    rescue ActiveRecord::InvalidForeignKey
      { error: "assignee_id and duplicate_of_id must name an existing user and issue" }
    end

    def add_comment(issue_id:, body:, actor: nil)
      issue = Issue.find_by(id: issue_id)
      return { error: "No issue found with id #{issue_id}" } unless issue

      comment = issue.comments.new(author: acting_for(actor), body: body, via_agent: true)
      return { error: comment.errors.full_messages.to_sentence } unless comment.save

      project(comment)
    end

    private

    # The person the run acts for: the signed-in teammate in the tracker's own
    # chat. A run started from the dashboard has no tracker user, so it is
    # attributed to the first support teammate.
    def acting_for(actor)
      actor.is_a?(User) ? actor : User.where(team: "support").order(:id).first!
    end

    def describe(issue)
      issue.changes.slice(*CHANGEABLE.map(&:to_s)).map do |attribute, (_, now)|
        case attribute
        when "assignee_id" then now ? "Assigned to #{User.find_by(id: now)&.name || "user #{now}"}." : "Unassigned."
        when "duplicate_of_id" then now ? "Marked as a duplicate of ##{now}." : "No longer marked as a duplicate."
        else "#{attribute.humanize} set to #{now.to_s.humanize(capitalize: false)}."
        end
      end.join(" ")
    end
  end
end
