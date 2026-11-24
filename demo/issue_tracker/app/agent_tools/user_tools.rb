# Who is on the team and which component each person owns, so an agent can
# turn "assign it to whoever owns auth" into an id.
class UserTools < ActiveAgent::SchemaTools
  model User

  filterable :handle, :team
  returns :id, :name, :handle, :team
end
