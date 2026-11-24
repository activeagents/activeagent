module ApplicationHelper
  def badge(kind, value)
    return if value.blank?

    tag.span(value.to_s.humanize(capitalize: false), class: "badge #{kind} #{kind}-#{value}")
  end

  def avatar(user)
    return tag.span("–", class: "avatar avatar-empty", title: "Unassigned") unless user

    tag.span(user.initials, class: "avatar", title: user.name)
  end

  def filter_link(label, overrides, count: nil)
    target = @filters.merge(overrides.stringify_keys).compact_blank
    current = overrides.all? { |key, value| @filters[key.to_s].to_s == value.to_s }
    link_to issues_path(target), class: [ "chip", ("chip-on" if current) ] do
      safe_join([ label, (tag.span(count, class: "chip-count") if count) ].compact, " ")
    end
  end
end
