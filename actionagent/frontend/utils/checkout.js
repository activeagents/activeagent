// Upgrade CTAs.
//
// The dashboard engine has no billing of its own — plans, checkout and
// subscriptions belong to whatever app mounts it. A host app that sells
// something points the dashboard at its own upgrade page:
//
//   ActiveAgent::Dashboard.upgrade_url = "/pricing"
//
// Without one, the CTAs report that there is nothing to upgrade rather than
// failing silently or posting to an endpoint that does not exist.
export async function startCheckout() {
  const upgradeUrl = window.ACTIVE_AGENT_DASHBOARD?.meta?.upgradeUrl;

  if (!upgradeUrl) {
    throw new Error('This dashboard has no billing configured.');
  }

  window.location.href = upgradeUrl;
}
