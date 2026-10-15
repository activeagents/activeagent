// Confirmations the dashboard asks in its own dialog (ConfirmHost) instead of
// window.confirm, which blocks the whole page, and browser automation with
// it, and cannot ask for the name of what is about to be deleted.
//
// One request is shown at a time. A second request while one is open answers
// the first with false, so a caller is never left waiting.

let current = null;
const listeners = new Set();

const notify = () => listeners.forEach((listener) => listener(current));

// Fills in a request's defaults.
//
//   title         the dialog's heading
//   message       what happens if the person confirms
//   confirmLabel  the confirm button (default "Confirm")
//   cancelLabel   the cancel button (default "Cancel")
//   danger        a destructive action: the confirm button is red
//   requireText   text the person must type exactly before confirming,
//                 such as the name of what is deleted
export function confirmRequest(options = {}) {
  const requireText = options.requireText == null ? null : String(options.requireText);
  return {
    title: options.title || 'Are you sure?',
    message: options.message || '',
    confirmLabel: options.confirmLabel || 'Confirm',
    cancelLabel: options.cancelLabel || 'Cancel',
    danger: Boolean(options.danger),
    requireText: requireText === '' ? null : requireText,
  };
}

// Asks for confirmation. Resolves true when the person confirms, false when
// they cancel or another request replaces this one.
export function requestConfirm(options) {
  if (current) current.resolve(false);
  return new Promise((resolve) => {
    current = { ...confirmRequest(options), resolve };
    notify();
  });
}

// Answers the open request, if any.
export function settleConfirm(confirmed) {
  if (!current) return;
  const { resolve } = current;
  current = null;
  notify();
  resolve(Boolean(confirmed));
}

export function currentConfirm() {
  return current;
}

// Calls +listener+ with the open request (or null) whenever it changes.
// Returns the unsubscribe function.
export function subscribeConfirm(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

// Whether +typed+ lets +request+ be confirmed: always, unless it requires
// text, which must then match exactly.
export function confirmTextMatches(request, typed) {
  if (!request?.requireText) return true;
  return typed === request.requireText;
}
