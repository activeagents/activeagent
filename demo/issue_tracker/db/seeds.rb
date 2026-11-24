# Fictional team and backlog for the demo. Everything here is invented.
# `bin/rails db:seed:replant` resets the tracker to this state between rehearsals.

team = {
  "alex"   => [ "Alex Kim",      "support" ],
  "priya"  => [ "Priya Nair",    "checkout" ],
  "marcus" => [ "Marcus Lee",    "billing" ],
  "sofia"  => [ "Sofia Alvarez", "auth" ],
  "dmitri" => [ "Dmitri Volkov", "search" ],
  "hana"   => [ "Hana Sato",     "notifications" ],
  "omar"   => [ "Omar Haddad",   "api" ]
}.to_h do |handle, (name, owns)|
  [ handle, User.create!(handle: handle, name: name, team: owns) ]
end

# [title, component, priority, status, assignee, reporter, days_ago, body]
backlog = [
  [ "Checkout returns 500 when a gift card covers the full total", "checkout", "urgent", "open", "priya", "alex", 1,
    "Orders where a gift card pays for everything fail at the last step with a 500.\n\nNoMethodError: undefined method `capture' for nil in PaymentsController#create. Started after Tuesday's deploy. 41 events in the last 24 hours." ],
  [ "Gift card orders crash on the payment step", "checkout", "medium", "open", nil, "hana", 0,
    "A customer wrote in: paying with only a gift card shows the error page instead of the confirmation. Card + gift card works fine." ],
  [ "Customers charged twice after retrying a timed-out payment", "billing", "urgent", "in_progress", "marcus", "alex", 2,
    "When the payment provider times out and the customer presses Pay again, both attempts settle. 6 confirmed double charges so far. Needs an idempotency key on the charge request." ],
  [ "Password reset email never arrives for some addresses", "auth", "high", "open", "sofia", "alex", 3,
    "Reset emails to addresses with a plus sign (name+tag@example.com) are never delivered. The address is being URL-decoded before it reaches the mailer." ],
  [ "Reset password link not received", "auth", "medium", "open", nil, "omar", 1,
    "Second report this week of a reset email not showing up. The user's address was first.last+shop@example.com." ],
  [ "Search returns no results for queries with an apostrophe", "search", "high", "open", nil, "alex", 4,
    "Searching for \"men's jacket\" returns nothing; \"mens jacket\" works. The query is escaped twice before it reaches the index." ],
  [ "Search results page is slow for one-letter queries", "search", "low", "open", "dmitri", "priya", 9,
    "p95 of 4.2s for single-character queries. Probably needs a minimum query length." ],
  [ "Order confirmation email shows the wrong currency symbol", "notifications", "medium", "open", "hana", "marcus", 5,
    "Orders placed in EUR show a $ in the confirmation email. The amount is right, the symbol is not." ],
  [ "Push notification sent twice when an order ships", "notifications", "low", "open", nil, "alex", 6,
    "Shipping notifications arrive twice on iOS. Android is fine." ],
  [ "API returns 200 with an empty body when the rate limit is hit", "api", "high", "open", "omar", "dmitri", 2,
    "Clients over the limit get a 200 and no body instead of a 429 with Retry-After. Integrations treat it as success and drop data." ],
  [ "Webhook signatures fail verification after secret rotation", "api", "high", "in_progress", "omar", "alex", 3,
    "For about ten minutes after rotating a webhook secret, deliveries are signed with the old one." ],
  [ "Invoice PDF total differs from the order total by one cent", "billing", "medium", "open", nil, "alex", 7,
    "Rounding happens per line on the PDF and on the sum in the order. Seen on orders with three or more discounted lines." ],
  [ "Refund button stays disabled after a partial refund", "billing", "medium", "open", "marcus", "hana", 8,
    "After refunding one line, the button for the remaining lines stays greyed out until the page is reloaded." ],
  [ "Sign-in with a passkey loops back to the sign-in page", "auth", "high", "open", nil, "priya", 1,
    "Safari 18 only. The passkey prompt succeeds, then the app redirects to sign-in again. Session cookie is not set." ],
  [ "Session expires in the middle of checkout", "auth", "medium", "open", "sofia", "alex", 10,
    "Customers who take longer than 20 minutes to check out are signed out and lose their cart." ],
  [ "Promo code field accepts expired codes", "checkout", "high", "open", nil, "marcus", 2,
    "Codes past their end date still apply the discount. The expiry check compares dates in different time zones." ],
  [ "Cart badge shows the wrong count after removing an item", "checkout", "low", "open", nil, "hana", 12,
    "The badge in the header only updates after a full page load." ],
  [ "Address autocomplete suggests addresses in the wrong country", "checkout", "low", "open", "priya", "alex", 14,
    "Customers in Canada are offered US addresses first." ],
  [ "Typo on the pricing page: \"anually\"", nil, "low", "open", nil, "omar", 3,
    "Second paragraph under the Team plan." ],
  [ "Export to CSV times out for accounts with more than 50k orders", "api", "medium", "open", nil, "alex", 5,
    "The export runs in the request. It should be a background job with an emailed link." ],
  [ "Dark mode: order status labels are unreadable", nil, "low", "open", nil, "priya", 11,
    "Grey text on a dark grey background in the orders list." ],
  [ "Email digest ignores the unsubscribe preference", "notifications", "high", "resolved", "hana", "alex", 15,
    "Weekly digests were sent to unsubscribed users. Fixed by checking the preference in the job, not the scheduler." ],
  [ "Checkout button unresponsive on double tap", "checkout", "medium", "closed", "priya", "hana", 20,
    "Fixed in the checkout form rewrite." ],
  [ "Search index misses products added in the last hour", "search", "medium", "resolved", "dmitri", "alex", 18,
    "Reindex job was scheduled hourly instead of on change." ]
]

issues = backlog.map do |title, component, priority, status, assignee, reporter, days_ago, body|
  at = days_ago.days.ago
  Issue.create!(title: title, body: body, component: component, priority: priority, status: status,
                assignee: team[assignee], reporter: team.fetch(reporter), created_at: at, updated_at: at,
                closed_at: (at + 2.days if status.in?(%w[resolved closed])))
end

by_title = issues.index_by(&:title)
{
  "Checkout returns 500 when a gift card covers the full total" => [
    [ "priya", "Reproduced. The capture call is skipped when the card amount is zero, then we call a method on the missing capture." ],
    [ "alex", "Support has 9 tickets on this now." ]
  ],
  "Customers charged twice after retrying a timed-out payment" => [
    [ "marcus", "Idempotency keys are in review. Refunds for the 6 affected customers are done." ]
  ],
  "Password reset email never arrives for some addresses" => [
    [ "sofia", "Confirmed for plus-addressed emails only." ]
  ]
}.each do |title, comments|
  comments.each { |handle, body| by_title.fetch(title).comments.create!(author: team.fetch(handle), body: body) }
end

puts "Seeded #{User.count} people and #{Issue.count} issues."
